#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/prove-release-matrix.sh --config FILE [--work-dir DIR] [--skip-build] [--only LABEL]

Builds and proves release combinations from a JSON config file. Each set creates
isolated artifacts, signed package repositories, local package signature
evidence, an airgap bundle, and optional release proof evidence.

Config example: docs/release-proof-matrix.example.json
EOF
}

config_file=
work_dir=matrix-runs
skip_build=0
only_label=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            config_file=${2:?--config requires a file}
            shift 2
            ;;
        --work-dir)
            work_dir=${2:?--work-dir requires a directory}
            shift 2
            ;;
        --skip-build)
            skip_build=1
            shift
            ;;
        --only)
            only_label=${2:?--only requires a label}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "${config_file}" ] || { usage >&2; exit 2; }
[ -f "${config_file}" ] || { echo "ERROR: config not found: ${config_file}" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

safe_label() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

need_tool jq
need_tool sha256sum
need_tool gpg

jq -e '.schema_version == "k8s-release.proof-matrix.v1" and (.sets | type == "array")' "${config_file}" >/dev/null ||
    fail "invalid proof matrix config"

mkdir -p "${work_dir}"
work_dir=$(cd "${work_dir}" && pwd)

tmp_dir=$(mktemp -d)
matrix_gpg_home=
cleanup() {
    rm -rf "${tmp_dir}"
    if [ -n "${matrix_gpg_home}" ]; then
        rm -rf "${matrix_gpg_home}"
    fi
}
trap cleanup EXIT

prepare_matrix_signing_key() {
    matrix_gpg_home=$(mktemp -d)
    chmod 700 "${matrix_gpg_home}"

    cat > "${matrix_gpg_home}/matrix-key.conf" <<'EOF'
Key-Type: RSA
Key-Length: 3072
Name-Real: k8s-release matrix artifact
Name-Email: k8s-release-matrix@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
    gpg --homedir "${matrix_gpg_home}" --batch --generate-key "${matrix_gpg_home}/matrix-key.conf" >/dev/null 2>&1
    matrix_fingerprint=$(gpg --homedir "${matrix_gpg_home}" --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "${matrix_fingerprint}" ] || fail "failed to create matrix artifact signing key"
}

sign_package_evidence() {
    local artifact_dir=$1
    local pkg sig pkg_sha sig_sha sig_bytes

    gpg --homedir "${matrix_gpg_home}" --batch --armor --export "${matrix_fingerprint}" > "${artifact_dir}/matrix-artifact-signing-key.asc"

    while IFS= read -r -d '' pkg; do
        sig="${pkg}.asc"
        gpg --homedir "${matrix_gpg_home}" \
            --batch \
            --yes \
            --local-user "${matrix_fingerprint}" \
            --armor \
            --detach-sign \
            -o "${sig}" \
            "${pkg}"
        pkg_sha=$(sha256sum "${pkg}" | awk '{print $1}')
        sig_sha=$(sha256sum "${sig}" | awk '{print $1}')
        sig_bytes=$(stat -c '%s' "${sig}" 2>/dev/null || stat -f '%z' "${sig}")
        cat > "${pkg}.sigstore.json" <<EOF
{
  "schema_version": "k8s-release.local-package-signature.v1",
  "package": "$(json_escape "$(basename "${pkg}")")",
  "package_sha256": "$(json_escape "${pkg_sha}")",
  "signature": "$(json_escape "$(basename "${sig}")")",
  "signature_sha256": "$(json_escape "${sig_sha}")",
  "signature_bytes": ${sig_bytes},
  "signing_key": "matrix-artifact-signing-key.asc",
  "signing_key_fingerprint": "$(json_escape "${matrix_fingerprint}")"
}
EOF
    done < <(find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -print0 | sort -z)
}

write_spdx() {
    local artifact_dir=$1
    local label=$2
    local output="${artifact_dir}/${label}.spdx.json"

    find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -print0 |
        sort -z |
        while IFS= read -r -d '' pkg; do
            name=$(basename "${pkg}")
            sha=$(sha256sum "${pkg}" | awk '{print $1}')
            jq -n --arg name "${name}" --arg sha "${sha}" '{
              name: $name,
              SPDXID: ("SPDXRef-" + ($name | gsub("[^A-Za-z0-9.-]"; "-"))),
              downloadLocation: "NOASSERTION",
              filesAnalyzed: false,
              checksums: [{algorithm: "SHA256", checksumValue: $sha}],
              licenseConcluded: "NOASSERTION",
              licenseDeclared: "NOASSERTION",
              copyrightText: "NOASSERTION"
            }'
        done |
        jq -s --arg label "${label}" '{
          spdxVersion: "SPDX-2.3",
          dataLicense: "CC0-1.0",
          SPDXID: "SPDXRef-DOCUMENT",
          name: ("k8s-release-" + $label),
          documentNamespace: ("https://example.invalid/k8s-release/" + $label),
          creationInfo: {
            created: "1970-01-01T00:00:00Z",
            creators: ["Tool: k8s-release prove-release-matrix"]
          },
          packages: .
        }' > "${output}"
}

build_component() {
    local component=$1
    local kube_version=$2
    local etcd_version=$3
    local flannel_version=$4
    local calico_version=$5
    local istio_version=$6
    local package_type=$7

    case "${component}" in
        kube-proxy|kubelet|kube-scheduler|kube-controller-manager|kube-apiserver|kubectl)
            KUBE_VERSION="${kube_version}" PACKAGE_TYPE="${package_type}" make "build-${component}"
            ;;
        etcd)
            ETCD_VERSION="${etcd_version}" PACKAGE_TYPE="${package_type}" make build-etcd
            ;;
        flannel)
            FLANNEL_VERSION="${flannel_version}" PACKAGE_TYPE="${package_type}" make build-flannel
            ;;
        calico)
            CALICO_VERSION="${calico_version}" PACKAGE_TYPE="${package_type}" make build-calico
            ;;
        istio)
            ISTIO_VERSION="${istio_version}" PACKAGE_TYPE="${package_type}" make build-istio
            ;;
        certificates)
            CERT_VERSION="${kube_version#v}" PACKAGE_TYPE="${package_type}" make build-certificates
            ;;
        *)
            fail "unsupported matrix component: ${component}"
            ;;
    esac
}

assemble_set() {
    local label=$1
    local kube_version=$2
    local etcd_version=$3
    local flannel_version=$4
    local calico_version=$5
    local istio_version=$6
    local package_type=$7
    local artifact_dir=$8
    local repo_dir=$9
    local bundle=${10}
    local package_pattern

    [ -d output ] || fail "output directory not found after build"
    case "${package_type}" in
        deb)
            package_pattern='*.deb'
            ;;
        rpm)
            package_pattern='*.rpm'
            ;;
        *)
            fail "unsupported package_type for ${label}: ${package_type}"
            ;;
    esac
    find output -maxdepth 1 -type f -name "${package_pattern}" | grep -q . ||
        fail "no ${package_type} packages were built for ${label}"

    rm -rf "${artifact_dir}" "${repo_dir}" "${bundle}"
    mkdir -p "${artifact_dir}"
    find output -maxdepth 1 -type f -name "${package_pattern}" -exec cp {} "${artifact_dir}/" \;
    (
        cd "${artifact_dir}"
        find . -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) -print0 |
            sort -z |
            xargs -0 sha256sum > SHA256SUMS
    )
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" ./scripts/generate-release-metadata.sh "${artifact_dir}" "${label}"
    write_spdx "${artifact_dir}" "${label}"
    sign_package_evidence "${artifact_dir}"
    ./scripts/smoke-install-packages.sh "${artifact_dir}"
    mkdir -p "${repo_dir}"
    ./scripts/create-package-repositories.sh "${artifact_dir}" "${repo_dir}"
    KUBE_VERSION="${kube_version}" \
    ETCD_VERSION="${etcd_version}" \
    FLANNEL_VERSION="${flannel_version}" \
    CALICO_VERSION="${calico_version}" \
    ISTIO_VERSION="${istio_version}" \
        ./scripts/generate-release-evidence.sh "${artifact_dir}" "${repo_dir}" "${artifact_dir}/release-evidence.md"
    cp "${repo_dir}/repo-signing-key.asc" "${artifact_dir}/repo-signing-key.asc"
    ./scripts/generate-release-passport.sh "${kube_version}" \
        --artifacts "${artifact_dir}" \
        --repos "${repo_dir}" \
        --output "${artifact_dir}/release-passport.md"
    ./scripts/create-airgap-bundle.sh "${kube_version}" \
        --airgap \
        --artifacts "${artifact_dir}" \
        --repos "${repo_dir}" \
        --output "${bundle}"
}

prepare_matrix_signing_key

set_count=$(jq '.sets | length' "${config_file}")
for index in $(seq 0 "$((set_count - 1))"); do
    label=$(jq -r ".sets[${index}].label" "${config_file}")
    [ "${label}" != "null" ] && [ -n "${label}" ] || fail "matrix set ${index} is missing label"
    if [ -n "${only_label}" ] && [ "${label}" != "${only_label}" ]; then
        continue
    fi

    safe=$(safe_label "${label}")
    kube_version=$(jq -r ".sets[${index}].kube_version // .defaults.kube_version // \"v1.36.1\"" "${config_file}")
    etcd_version=$(jq -r ".sets[${index}].etcd_version // .defaults.etcd_version // \"v3.6.11\"" "${config_file}")
    flannel_version=$(jq -r ".sets[${index}].flannel_version // .defaults.flannel_version // \"v0.28.4\"" "${config_file}")
    calico_version=$(jq -r ".sets[${index}].calico_version // .defaults.calico_version // \"v3.32.0\"" "${config_file}")
    istio_version=$(jq -r ".sets[${index}].istio_version // .defaults.istio_version // \"1.30.0\"" "${config_file}")
    package_type=$(jq -r ".sets[${index}].package_type // .defaults.package_type // \"deb\"" "${config_file}")
    prove=$(jq -r ".sets[${index}].prove // false" "${config_file}")
    previous_label=$(jq -r ".sets[${index}].previous_label // \"\"" "${config_file}")
    policy=$(jq -r ".sets[${index}].policy // .defaults.policy // \"\"" "${config_file}")

    artifact_dir="${work_dir}/release-artifacts-${safe}"
    repo_dir="${work_dir}/package-repositories-${safe}"
    bundle="${work_dir}/k8s-${safe}-airgap.tar"

    log "Matrix set ${label}: ${kube_version}, package_type=${package_type}"

    if [ "${skip_build}" -eq 0 ]; then
        rm -rf output
        mkdir -p output
        mapfile -t components < <(jq -r ".sets[${index}].components // .defaults.components // [] | .[]" "${config_file}")
        [ "${#components[@]}" -gt 0 ] || fail "matrix set ${label} has no components"
        for component in "${components[@]}"; do
            log "Building ${component} for ${label}"
            build_component "${component}" "${kube_version}" "${etcd_version}" "${flannel_version}" "${calico_version}" "${istio_version}" "${package_type}"
        done
    fi

    assemble_set "${label}" "${kube_version}" "${etcd_version}" "${flannel_version}" "${calico_version}" "${istio_version}" "${package_type}" "${artifact_dir}" "${repo_dir}" "${bundle}"

    if [ "${prove}" = "true" ]; then
        previous_args=()
        if [ -n "${previous_label}" ]; then
            previous_safe=$(safe_label "${previous_label}")
            previous_version=$(jq -r --arg label "${previous_label}" '.sets[] | select(.label == $label) | .kube_version' "${config_file}" | head -n 1)
            [ -n "${previous_version}" ] || fail "previous_label not found: ${previous_label}"
            previous_args=(
                --previous "${previous_version}"
                --previous-artifacts "${work_dir}/release-artifacts-${previous_safe}"
                --previous-repos "${work_dir}/package-repositories-${previous_safe}"
                --previous-bundle "${work_dir}/k8s-${previous_safe}-airgap.tar"
            )
        fi
        policy_args=()
        if [ -n "${policy}" ] && [ "${policy}" != "null" ]; then
            policy_args=(--policy "${policy}")
        fi
        log "Proving ${label}"
        ./scripts/prove-release.sh "${kube_version}" \
            --artifacts "${artifact_dir}" \
            --repos "${repo_dir}" \
            --bundle "${bundle}" \
            "${previous_args[@]}" \
            "${policy_args[@]}"
        ./scripts/verify-proof.sh "${artifact_dir}/release-proof.json"
    fi
done

log "Matrix run complete: ${work_dir}"
