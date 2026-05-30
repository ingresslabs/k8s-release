#!/usr/bin/env bash
set -euo pipefail

if [ -f ./.env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/prove-release.sh <version> [options]

Runs the one-command Release Proof Engine on the local machine. The proof uses
local release artifacts or a local airgap bundle, runs L4 signed-repository,
airgap, cluster smoke, and optional upgrade checks, then writes
machine-readable proof JSON and human-readable reports into the artifact set.

Options:
  --artifacts DIR             Current release artifacts (default: release-artifacts)
  --repos DIR                 Current package repositories (default: package-repositories)
  --bundle FILE               Current airgap bundle (default: k8s-<version>-airgap.tar)
  --policy FILE               Policy-as-code file for release readiness
  --host HOST                 Use remote k2vm cluster smoke on HOST or USER@HOST
  --remote-dir DIR            Remote working directory for k2vm cluster smoke
  --keep-remote               Keep the remote k2vm working directory after success
  --previous VERSION          Previous Kubernetes version for upgrade proof
  --previous-artifacts DIR    Previous release artifacts (default: release-artifacts-<previous>)
  --previous-repos DIR        Previous package repositories (default: package-repositories-<previous>)
  --previous-bundle FILE      Previous airgap bundle; used if previous dirs are absent

Example:
  k8s-release prove v1.36.1 --previous v1.36.0
  k8s-release prove v1.36.1 --host root@proof-host --previous v1.36.0
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

version=${1:-}
if [ -z "${version}" ]; then
    usage >&2
    exit 2
fi
shift

tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac

artifact_dir=release-artifacts
repo_dir=package-repositories
bundle=
previous_version=
previous_artifact_dir=
previous_repo_dir=
previous_bundle=
policy_file=
proof_host=
proof_remote_dir=
keep_proof_remote=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifacts)
            artifact_dir=${2:?--artifacts requires a directory}
            shift 2
            ;;
        --repos)
            repo_dir=${2:?--repos requires a directory}
            shift 2
            ;;
        --bundle)
            bundle=${2:?--bundle requires a file}
            shift 2
            ;;
        --policy)
            policy_file=${2:?--policy requires a file}
            shift 2
            ;;
        --host)
            proof_host=${2:?--host requires a host}
            shift 2
            ;;
        --remote-dir)
            proof_remote_dir=${2:?--remote-dir requires a directory}
            shift 2
            ;;
        --keep-remote)
            keep_proof_remote=1
            shift
            ;;
        --previous)
            previous_version=${2:?--previous requires a version}
            shift 2
            ;;
        --previous-artifacts)
            previous_artifact_dir=${2:?--previous-artifacts requires a directory}
            shift 2
            ;;
        --previous-repos)
            previous_repo_dir=${2:?--previous-repos requires a directory}
            shift 2
            ;;
        --previous-bundle)
            previous_bundle=${2:?--previous-bundle requires a file}
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

if [ -z "${proof_host}" ]; then
    proof_host=${K8S_RELEASE_PROOF_HOST:-}
fi
if [ -z "${proof_remote_dir}" ]; then
    proof_remote_dir=${K8S_RELEASE_PROOF_REMOTE_DIR:-}
fi

if [ -z "${proof_host}" ] && { [ -n "${proof_remote_dir}" ] || [ "${keep_proof_remote}" -eq 1 ]; }; then
    echo "ERROR: --remote-dir and --keep-remote require --host." >&2
    usage >&2
    exit 2
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

log() {
    printf '==> %s\n' "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

same_directory() {
    local first=$1
    local second=$2
    local first_real second_real

    [ -d "${first}" ] && [ -d "${second}" ] || return 1
    first_real=$(cd "${first}" && pwd -P)
    second_real=$(cd "${second}" && pwd -P)
    [ "${first_real}" = "${second_real}" ]
}

dir_has_packages() {
    local dir=$1
    [ -d "${dir}" ] || return 1
    find "${dir}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) | grep -q .
}

find_bundle_candidate() {
    local version_tag=$1
    local artifact_path=$2
    local explicit=$3

    if [ -n "${explicit}" ]; then
        printf '%s\n' "${explicit}"
        return
    fi
    if [ -f "${artifact_path}/k8s-${version_tag}-airgap.tar" ]; then
        printf '%s\n' "${artifact_path}/k8s-${version_tag}-airgap.tar"
    else
        printf '%s\n' "k8s-${version_tag}-airgap.tar"
    fi
}

extract_bundle_inputs() {
    local bundle_file=$1
    local target_artifacts=$2
    local target_repos=$3
    local tmp root

    [ -f "${bundle_file}" ] || fail "cannot extract missing bundle ${bundle_file}"
    tmp=$(mktemp -d)
    tar -xf "${bundle_file}" -C "${tmp}"
    root=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
    [ -n "${root}" ] || fail "bundle ${bundle_file} has no top-level directory"
    [ -d "${root}/release-artifacts" ] || fail "bundle ${bundle_file} is missing release-artifacts"
    [ -d "${root}/package-repositories" ] || fail "bundle ${bundle_file} is missing package-repositories"
    mkdir -p "${target_artifacts}" "${target_repos}"
    cp -a "${root}/release-artifacts/." "${target_artifacts}/"
    cp -a "${root}/package-repositories/." "${target_repos}/"
    rm -rf "${tmp}"
}

ensure_release_evidence() {
    local artifacts=$1
    local repos=$2

    if [ ! -f "${artifacts}/release-evidence.md" ]; then
        KUBE_VERSION="${tag}" ./scripts/generate-release-evidence.sh \
            "${artifacts}" \
            "${repos}" \
            "${artifacts}/release-evidence.md"
    fi
    if [ -f "${repos}/repo-signing-key.asc" ]; then
        cp "${repos}/repo-signing-key.asc" "${artifacts}/repo-signing-key.asc"
    fi
}

json_array_for_files() {
    local dir=$1
    shift

    find "${dir}" -maxdepth 1 -type f "$@" -print0 |
        sort -z |
        while IFS= read -r -d '' file; do
            name=$(basename "${file}")
            sha=$(sha256sum "${file}" | awk '{print $1}')
            bytes=$(stat -c '%s' "${file}" 2>/dev/null || stat -f '%z' "${file}")
            jq -n --arg name "${name}" --arg sha256 "${sha}" --argjson bytes "${bytes}" \
                '{name: $name, sha256: $sha256, bytes: $bytes}'
        done |
        jq -s .
}

policy_value() {
    local key=$1

    [ -n "${policy_file}" ] || return 1
    awk -v key="${key}" '
        /^[[:space:]]*required:[[:space:]]*$/ {in_required=1; next}
        in_required && /^[^[:space:]]/ {in_required=0}
        in_required {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)
            pattern="^[[:space:]]*" key "[[:space:]]*:"
            if (line ~ pattern) {
                sub("^[^:]*:", "", line)
                gsub(/[[:space:]]/, "", line)
                gsub(/"/, "", line)
                gsub(/\047/, "", line)
                print tolower(line)
                exit
            }
        }
    ' "${policy_file}"
}

policy_requires() {
    local value
    value=$(policy_value "$1" || true)
    case "${value}" in
        true|yes|1|required)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

enforce_policy() {
    [ -n "${policy_file}" ] || return 0
    [ -f "${policy_file}" ] || fail "policy file not found: ${policy_file}"

    log "Applying release policy ${policy_file}"

    if policy_requires upgrade_from_previous && [ -z "${previous_version}" ]; then
        fail "policy requires upgrade_from_previous; pass --previous VERSION"
    fi
    if policy_requires rollback && [ -z "${previous_version}" ]; then
        fail "policy requires rollback; pass --previous VERSION"
    fi
    if policy_requires signed_repos; then
        [ -s "${work_repo_dir}/repo-signing-key.asc" ] || fail "policy requires signed repositories; missing repo-signing-key.asc"
        signed_metadata=$(
            {
                find "${work_repo_dir}/debian/dists" -type f -name Release.gpg 2>/dev/null || true
                find "${work_repo_dir}/rpm/repodata" -type f -name repomd.xml.asc 2>/dev/null || true
            } | wc -l | tr -d ' '
        )
        [ "${signed_metadata}" -gt 0 ] || fail "policy requires signed repository metadata"
    fi
    if policy_requires airgap_bundle; then
        [ -f "${bundle}" ] || fail "policy requires an airgap bundle: ${bundle}"
    fi
    if policy_requires sbom && ! find "${work_artifact_dir}" -maxdepth 1 -type f -name '*.spdx.json' | grep -q .; then
        fail "policy requires SPDX SBOMs"
    fi
    if policy_requires provenance && ! find "${work_artifact_dir}" -maxdepth 1 -type f -name '*.sigstore.json' | grep -q .; then
        fail "policy requires provenance/signature bundles"
    fi
}

prepare_proof_signing_key() {
    proof_gpg_home=$(mktemp -d)
    chmod 700 "${proof_gpg_home}"

    if [ -n "${RELEASE_PROOF_GPG_PRIVATE_KEY:-}" ]; then
        printf '%s\n' "${RELEASE_PROOF_GPG_PRIVATE_KEY}" | gpg --homedir "${proof_gpg_home}" --batch --import
    else
        cat > "${proof_gpg_home}/proof-key.conf" <<'EOF'
Key-Type: RSA
Key-Length: 3072
Name-Real: k8s-release proof
Name-Email: k8s-release-proof@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
        gpg --homedir "${proof_gpg_home}" --batch --generate-key "${proof_gpg_home}/proof-key.conf" >/dev/null 2>&1
    fi

    proof_fingerprint=$(gpg --homedir "${proof_gpg_home}" --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "${proof_fingerprint}" ] || fail "no proof signing key is available"
    gpg --homedir "${proof_gpg_home}" --batch --armor --export "${proof_fingerprint}" > "${work_artifact_dir}/release-proof-signing-key.asc"
}

sign_file() {
    local file=$1

    gpg --homedir "${proof_gpg_home}" \
        --batch \
        --yes \
        --local-user "${proof_fingerprint}" \
        --armor \
        --detach-sign \
        -o "${file}.asc" \
        "${file}"
}

write_canonical_proof() {
    local local_proof_json source_repo source_ref source_commit generated_at
    local packages_json sboms_json reports_json manifests_json policy_json cluster_artifacts_json

    local_proof_json=$(find "${work_artifact_dir}" -maxdepth 1 -type f -name '*-release-proof.json' ! -name 'release-proof.json' | sort | head -n 1)
    [ -n "${local_proof_json}" ] || fail "missing L4 release proof JSON"

    packages_json=$(mktemp)
    sboms_json=$(mktemp)
    reports_json=$(mktemp)
    manifests_json=$(mktemp)
    policy_json=$(mktemp)
    cluster_artifacts_json=$(mktemp)

    json_array_for_files "${work_artifact_dir}" \( -name '*.deb' -o -name '*.rpm' \) > "${packages_json}"
    json_array_for_files "${work_artifact_dir}" -name '*.spdx.json' > "${sboms_json}"
    json_array_for_files "${work_artifact_dir}" \( -name '*-smoke.txt' -o -name '*-install.txt' -o -name '*-verify.txt' -o -name 'release-evidence.md' -o -name 'release-passport.md' \) > "${reports_json}"
    json_array_for_files "${work_artifact_dir}" -name '*-release-manifest.json' > "${manifests_json}"
    json_array_for_files "${work_artifact_dir}" -name '*-cluster-smoke-*' > "${cluster_artifacts_json}"
    if [ -n "${policy_file}" ]; then
        jq -Rs '{format: "yaml", raw: .}' "${policy_file}" > "${policy_json}"
    else
        printf 'null\n' > "${policy_json}"
    fi

    source_repo=${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null || echo local)}
    source_ref=${GITHUB_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}
    source_commit=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -n \
        --arg schema "k8s-release.proof.v1" \
        --arg status "passed" \
        --arg generated_at "${generated_at}" \
        --arg version "${tag}" \
        --arg previous "${previous_tag}" \
        --arg source_repo "${source_repo}" \
        --arg source_ref "${source_ref}" \
        --arg source_commit "${source_commit}" \
        --arg hostname "$(hostname 2>/dev/null || echo unknown)" \
        --arg os "$(awk -F= '/^PRETTY_NAME=/ {gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || sw_vers -productVersion 2>/dev/null || echo unknown)" \
        --arg kernel "$(uname -a 2>/dev/null || echo unknown)" \
        --arg docker "$(docker --version 2>/dev/null || echo unavailable)" \
        --arg bundle "$(basename "${bundle}")" \
        --slurpfile l4 "${local_proof_json}" \
        --slurpfile packages "${packages_json}" \
        --slurpfile sboms "${sboms_json}" \
        --slurpfile reports "${reports_json}" \
        --slurpfile manifests "${manifests_json}" \
        --slurpfile cluster_artifacts "${cluster_artifacts_json}" \
        --slurpfile policy "${policy_json}" \
        '($l4[0].gates // []) as $gates |
        {
          schema_version: $schema,
          status: $status,
          generated_at: $generated_at,
          kubernetes_version: $version,
          previous_version: (if $previous == "" then null else $previous end),
          source: {
            repository: $source_repo,
            ref: $source_ref,
            commit: $source_commit
          },
          builder_identity: {
            hostname: $hostname,
            os: $os,
            kernel: $kernel,
            docker: $docker
          },
          policy: $policy[0],
          results: {
            airgap_bundle: (($gates[]? | select(.name == "airgap_bundle_verify") | .status) // "missing"),
            signed_repo_install: (($gates[]? | select(.name == "signed_repo_install") | .status) // "missing"),
            airgap_install: (($gates[]? | select(.name == "airgap_install") | .status) // "missing"),
            cluster_smoke: (($gates[]? | select(.name == "cluster_smoke") | .status) // "missing"),
            upgrade_and_rollback: (($gates[]? | select(.name == "upgrade_rollback_smoke") | .status) // (if ($previous == "") then "not_required" else "missing" end))
          },
          artifacts: {
            airgap_bundle: $bundle,
            package_checksums: $packages[0],
            sbom_references: $sboms[0],
            release_manifests: $manifests[0],
            cluster_smoke_artifacts: $cluster_artifacts[0],
            evidence_reports: $reports[0]
          },
          gates: $gates
        }' > "${work_artifact_dir}/release-proof.json"
}

create_release_evidence_tar() {
    local evidence_tar="${work_artifact_dir}/release-evidence.tar"

    (
        cd "${work_artifact_dir}"
        shopt -s nullglob
        evidence_files=(
            release-proof.json
            release-proof.json.asc
            release-proof-signing-key.asc
            release-passport.md
            release-evidence.md
            SHA256SUMS
            *-release-proof.json
            *-release-manifest.json
            *-cluster-smoke-*
            *-smoke.txt
            *-install.txt
            *-verify.txt
            *.spdx.json
            *.sigstore.json
        )
        tar -cf release-evidence.tar "${evidence_files[@]}"
        sha256sum release-evidence.tar > release-evidence.tar.sha256
    )

    sign_file "${evidence_tar}"
}

need_tool docker
need_tool tar
need_tool sha256sum
need_tool gpg
need_tool jq

tmp_dir=$(mktemp -d)
proof_gpg_home=
cleanup() {
    rm -rf "${tmp_dir}"
    if [ -n "${proof_gpg_home}" ]; then
        rm -rf "${proof_gpg_home}"
    fi
}
trap cleanup EXIT

bundle=$(find_bundle_candidate "${tag}" "${artifact_dir}" "${bundle}")

work_artifact_dir=${artifact_dir}
work_repo_dir=${repo_dir}
if ! dir_has_packages "${artifact_dir}" || [ ! -d "${repo_dir}" ]; then
    [ -f "${bundle}" ] || fail "current artifacts/repos are incomplete and no airgap bundle was found at ${bundle}"
    log "Extracting current proof inputs from ${bundle}"
    work_artifact_dir="${tmp_dir}/release-artifacts"
    work_repo_dir="${tmp_dir}/package-repositories"
    extract_bundle_inputs "${bundle}" "${work_artifact_dir}" "${work_repo_dir}"
fi

if [ ! -f "${bundle}" ]; then
    log "Creating local airgap bundle ${bundle}"
    ensure_release_evidence "${work_artifact_dir}" "${work_repo_dir}"
    ./scripts/create-airgap-bundle.sh "${tag}" \
        --airgap \
        --artifacts "${work_artifact_dir}" \
        --repos "${work_repo_dir}" \
        --output "${bundle}"
fi

enforce_policy

previous_tag=
previous_args=()
require_args=(--require-l4)
l4_cluster_smoke_args=()
if [ -n "${previous_version}" ]; then
    previous_tag=${previous_version}
    case "${previous_tag}" in
        v*) ;;
        *) previous_tag="v${previous_tag}" ;;
    esac
    previous_artifact_dir=${previous_artifact_dir:-release-artifacts-${previous_tag}}
    previous_repo_dir=${previous_repo_dir:-package-repositories-${previous_tag}}
    previous_bundle=$(find_bundle_candidate "${previous_tag}" "${previous_artifact_dir}" "${previous_bundle}")

    work_previous_artifact_dir=${previous_artifact_dir}
    work_previous_repo_dir=${previous_repo_dir}
    if ! dir_has_packages "${previous_artifact_dir}" || [ ! -d "${previous_repo_dir}" ]; then
        [ -f "${previous_bundle}" ] || fail "previous artifacts/repos are incomplete and no previous airgap bundle was found at ${previous_bundle}"
        log "Extracting previous proof inputs from ${previous_bundle}"
        work_previous_artifact_dir="${tmp_dir}/previous-release-artifacts"
        work_previous_repo_dir="${tmp_dir}/previous-package-repositories"
        extract_bundle_inputs "${previous_bundle}" "${work_previous_artifact_dir}" "${work_previous_repo_dir}"
    fi

    previous_args=(
        --previous "${previous_tag}"
        --previous-artifacts "${work_previous_artifact_dir}"
        --previous-repos "${work_previous_repo_dir}"
    )
    require_args+=(--require-upgrade)
fi

if [ -n "${proof_host}" ]; then
    l4_cluster_smoke_args=(
        --cluster-smoke-backend k2vm
        --cluster-smoke-host "${proof_host}"
    )
    if [ -n "${proof_remote_dir}" ]; then
        l4_cluster_smoke_args+=(--cluster-smoke-remote-dir "${proof_remote_dir}")
    fi
    if [ "${keep_proof_remote}" -eq 1 ]; then
        l4_cluster_smoke_args+=(--keep-cluster-smoke-remote)
    fi
    log "Running release proof for ${tag} with remote k2vm cluster smoke on ${proof_host}"
else
    log "Running local release proof for ${tag}"
fi

l4_proof_cmd=(
    ./scripts/l4-release-proof.sh "${tag}"
    --artifacts "${work_artifact_dir}"
    --repos "${work_repo_dir}"
    --bundle "${bundle}"
    --output-dir "${work_artifact_dir}"
    --host-label local
)
if [ "${#l4_cluster_smoke_args[@]}" -gt 0 ]; then
    l4_proof_cmd+=("${l4_cluster_smoke_args[@]}")
fi
if [ "${#previous_args[@]}" -gt 0 ]; then
    l4_proof_cmd+=("${previous_args[@]}")
fi

"${l4_proof_cmd[@]}"

ensure_release_evidence "${work_artifact_dir}" "${work_repo_dir}"
./scripts/generate-release-passport.sh "${tag}" \
    --artifacts "${work_artifact_dir}" \
    --repos "${work_repo_dir}" \
    --output "${work_artifact_dir}/release-passport.md"

prepare_proof_signing_key
write_canonical_proof
sign_file "${work_artifact_dir}/release-proof.json"
create_release_evidence_tar

log "Creating proof-enforced airgap bundle"
./scripts/create-airgap-bundle.sh "${tag}" \
    --airgap \
    --artifacts "${work_artifact_dir}" \
    --repos "${work_repo_dir}" \
    --output "${work_artifact_dir}/$(basename "${bundle}")" \
    "${require_args[@]}"

./scripts/verify-bundle.sh "${work_artifact_dir}/$(basename "${bundle}")"

mkdir -p "${artifact_dir}"
if ! same_directory "${work_artifact_dir}" "${artifact_dir}"; then
    cp -a "${work_artifact_dir}/." "${artifact_dir}/"
fi

echo "Release proof completed for ${tag}."
echo "Evidence directory: ${artifact_dir}"
