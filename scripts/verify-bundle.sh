#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/verify-bundle.sh <bundle.tar> [--repo OWNER/REPO] [--online] [--keep DIR]

Verifies an airgap bundle by checking bundle-level checksums, release artifact
checksums and manifests, SPDX SBOM shape, required signature/provenance files,
signed apt/yum repository metadata, release evidence, release passport, and the
bundled verification policy.

Use --online to also run the full release verifier against GitHub attestations
and Sigstore workflow identity.
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

bundle=${1:-}
if [ -z "${bundle}" ]; then
    usage
    exit 2
fi
shift

repo=${GITHUB_REPOSITORY:-}
online=0
keep_dir=
issuer=https://token.actions.githubusercontent.com
identity_regexp=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            repo=${2:?--repo requires OWNER/REPO}
            shift 2
            ;;
        --online)
            online=1
            shift
            ;;
        --keep)
            keep_dir=${2:?--keep requires a directory}
            shift 2
            ;;
        --identity-regexp)
            identity_regexp=${2:?--identity-regexp requires a regex}
            shift 2
            ;;
        --issuer)
            issuer=${2:?--issuer requires an OIDC issuer}
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

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

[ -f "${bundle}" ] || { echo "ERROR: bundle not found: ${bundle}" >&2; exit 1; }
bundle=$(cd "$(dirname "${bundle}")" && pwd)/$(basename "${bundle}")

log() {
    printf '==> %s\n' "$*"
}

pass() {
    printf 'PASS: %s\n' "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

tmp_dir=${keep_dir:-$(mktemp -d)}
cleanup() {
    if [ -z "${keep_dir}" ]; then
        rm -rf "${tmp_dir}"
    fi
}
trap cleanup EXIT
mkdir -p "${tmp_dir}"

need_tool tar
need_tool sha256sum

log "Extracting $(basename "${bundle}")"
tar -xf "${bundle}" -C "${tmp_dir}"

roots=()
while IFS= read -r root; do
    roots+=("${root}")
done < <(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
[ "${#roots[@]}" -eq 1 ] || fail "bundle must contain exactly one top-level directory"
bundle_root=${roots[0]}
artifact_dir="${bundle_root}/release-artifacts"
repo_dir="${bundle_root}/package-repositories"
metadata_dir="${bundle_root}/metadata"

[ -d "${artifact_dir}" ] || fail "missing release-artifacts directory"
[ -d "${repo_dir}" ] || fail "missing package-repositories directory"
[ -d "${metadata_dir}" ] || fail "missing metadata directory"
[ -f "${metadata_dir}/bundle-manifest.json" ] || fail "missing metadata/bundle-manifest.json"
[ -f "${metadata_dir}/verification-policy.json" ] || fail "missing metadata/verification-policy.json"
[ -f "${metadata_dir}/BUNDLE-SHA256SUMS" ] || fail "missing metadata/BUNDLE-SHA256SUMS"

if command -v jq >/dev/null 2>&1; then
    jq -e '.schema_version == "k8s-release.airgap-bundle.v1" and .kubernetes_version' "${metadata_dir}/bundle-manifest.json" >/dev/null ||
        fail "invalid bundle manifest"
    jq -e '.schema_version == "k8s-release.verification-policy.v1" and .required.bundle_checksums == true' "${metadata_dir}/verification-policy.json" >/dev/null ||
        fail "invalid verification policy"
    if jq -e '.required.l4_cluster_smoke == true' "${metadata_dir}/verification-policy.json" >/dev/null; then
        require_l4=1
    else
        require_l4=0
    fi
    if jq -e '.required.upgrade_smoke == true' "${metadata_dir}/verification-policy.json" >/dev/null; then
        require_upgrade=1
    else
        require_upgrade=0
    fi
else
    require_l4=0
    require_upgrade=0
fi

log "Verifying bundle checksums"
(
    cd "${bundle_root}"
    sha256sum -c metadata/BUNDLE-SHA256SUMS >/dev/null
)
pass "bundle checksums match"

log "Verifying release artifact checksums"
[ -f "${artifact_dir}/SHA256SUMS" ] || fail "missing release-artifacts/SHA256SUMS"
checked=0
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    expected=$(printf '%s\n' "${line}" | awk '{print $1}')
    raw_path=$(printf '%s\n' "${line}" | sed -E 's/^[0-9a-fA-F]{64}[[:space:]]+[*]?//')
    [ -n "${expected}" ] && [ -n "${raw_path}" ] || fail "invalid checksum line: ${line}"
    candidate=
    if [ -f "${artifact_dir}/${raw_path}" ]; then
        candidate=${artifact_dir}/${raw_path}
    elif [ -f "${artifact_dir}/$(basename "${raw_path}")" ]; then
        candidate=${artifact_dir}/$(basename "${raw_path}")
    else
        fail "checksum target not found: ${raw_path}"
    fi
    actual=$(sha256sum "${candidate}" | awk '{print $1}')
    [ "${actual}" = "${expected}" ] || fail "checksum mismatch for ${raw_path}"
    checked=$((checked + 1))
done < "${artifact_dir}/SHA256SUMS"
[ "${checked}" -gt 0 ] || fail "release-artifacts/SHA256SUMS has no entries"
pass "release artifact checksums match (${checked} files)"

shopt -s nullglob
packages=("${artifact_dir}"/*.deb "${artifact_dir}"/*.rpm)
sboms=("${artifact_dir}"/*.spdx.json)
manifests=("${artifact_dir}"/*-release-manifest.json "${artifact_dir}"/release-manifest.json)

[ "${#packages[@]}" -gt 0 ] || fail "no DEB/RPM packages found"
[ "${#sboms[@]}" -gt 0 ] || fail "no SPDX SBOM files found"

if [ "${require_l4}" -eq 1 ] && ! find "${artifact_dir}" -maxdepth 1 -type f -name '*-l4-smoke.txt' | grep -q .; then
    fail "verification policy requires L4 cluster smoke evidence"
fi
if [ "${require_l4}" -eq 1 ] && ! find "${artifact_dir}" -maxdepth 1 -type f -name '*-release-proof.json' | grep -q .; then
    fail "verification policy requires machine-readable release proof evidence"
fi
if [ "${require_upgrade}" -eq 1 ] && ! find "${artifact_dir}" -maxdepth 1 -type f -name '*-upgrade-smoke.txt' | grep -q .; then
    fail "verification policy requires upgrade smoke evidence"
fi

if command -v jq >/dev/null 2>&1; then
    log "Verifying release manifests and SPDX SBOM shape"
    manifest_count=0
    for manifest in "${manifests[@]}"; do
        [ -f "${manifest}" ] || continue
        manifest_count=$((manifest_count + 1))
        jq -e '.artifacts | type == "array" and length > 0' "${manifest}" >/dev/null ||
            fail "invalid release manifest: ${manifest}"
        while IFS=$'\t' read -r name expected; do
            [ -n "${name}" ] && [ -n "${expected}" ] || fail "invalid artifact entry in ${manifest}"
            candidate="${artifact_dir}/${name}"
            [ -f "${candidate}" ] || fail "manifest target not found: ${name}"
            actual=$(sha256sum "${candidate}" | awk '{print $1}')
            [ "${actual}" = "${expected}" ] || fail "manifest checksum mismatch for ${name}"
        done < <(jq -r '.artifacts[] | [.name, .sha256] | @tsv' "${manifest}")
    done
    [ "${manifest_count}" -gt 0 ] || fail "missing release manifest JSON"

    for sbom in "${sboms[@]}"; do
        jq -e '.spdxVersion and .SPDXID and (.packages | type == "array")' "${sbom}" >/dev/null ||
            fail "invalid SPDX SBOM: ${sbom}"
    done

    for proof in "${artifact_dir}"/*-release-proof.json; do
        [ -f "${proof}" ] || continue
        jq -e '.schema_version == "k8s-release.release-proof.v1" and .status == "passed" and (.gates | type == "array")' "${proof}" >/dev/null ||
            fail "invalid release proof JSON: ${proof}"
    done
    pass "release manifests and SPDX SBOMs parse"
else
    pass "jq unavailable; checksum-only artifact verification completed"
fi

log "Checking Sigstore bundle files"
for pkg in "${packages[@]}"; do
    [ -f "${pkg}.sigstore.json" ] || fail "missing Sigstore bundle for $(basename "${pkg}")"
done
pass "Sigstore bundle files present for ${#packages[@]} packages"

[ -f "${artifact_dir}/release-evidence.md" ] || fail "missing release-evidence.md"
[ -f "${artifact_dir}/release-passport.md" ] || fail "missing release-passport.md"
pass "release evidence and passport are present"

log "Verifying package repository checksums"
[ -f "${repo_dir}/SHA256SUMS" ] || fail "missing package-repositories/SHA256SUMS"
(
    cd "${repo_dir}"
    sha256sum -c SHA256SUMS >/dev/null
)
pass "package repository checksums match"

log "Verifying signed repository metadata"
[ -f "${repo_dir}/repo-signing-key.asc" ] || fail "missing repository signing key"
need_tool gpg
gpg_home=$(mktemp -d)
chmod 700 "${gpg_home}"
gpg --homedir "${gpg_home}" --batch --import "${repo_dir}/repo-signing-key.asc" >/dev/null 2>&1

repo_signature_count=0
while IFS= read -r release_file; do
    [ -n "${release_file}" ] || continue
    release_sig="$(dirname "${release_file}")/Release.gpg"
    [ -f "${release_sig}" ] || fail "missing Debian repository signature for ${release_file}"
    gpg --homedir "${gpg_home}" --batch --verify \
        "${release_sig}" \
        "${release_file}" >/dev/null 2>&1 ||
        fail "Debian repository signature verification failed for ${release_file}"
    repo_signature_count=$((repo_signature_count + 1))
done < <(find "${repo_dir}/debian/dists" -type f -name Release 2>/dev/null | sort)

if [ -f "${repo_dir}/rpm/repodata/repomd.xml" ] && [ -f "${repo_dir}/rpm/repodata/repomd.xml.asc" ]; then
    gpg --homedir "${gpg_home}" --batch --verify \
        "${repo_dir}/rpm/repodata/repomd.xml.asc" \
        "${repo_dir}/rpm/repodata/repomd.xml" >/dev/null 2>&1 ||
        fail "RPM repository signature verification failed"
    repo_signature_count=$((repo_signature_count + 1))
fi
[ "${repo_signature_count}" -gt 0 ] || fail "no signed apt/yum repository metadata found"
rm -rf "${gpg_home}"
pass "repository metadata signatures verify (${repo_signature_count} signed metadata files)"

if [ "${online}" -eq 1 ]; then
    log "Running online release verification"
    args=(./scripts/verify-release.sh)
    version=$(awk -F'"' '/"kubernetes_version"/ {print $4; exit}' "${metadata_dir}/bundle-manifest.json")
    [ -n "${version}" ] || fail "cannot read kubernetes_version from bundle manifest"
    args+=("${version}" --dir "${artifact_dir}")
    if [ -n "${repo}" ]; then
        args+=(--repo "${repo}")
    fi
    if [ -n "${identity_regexp}" ]; then
        args+=(--identity-regexp "${identity_regexp}")
    fi
    args+=(--issuer "${issuer}")
    "${args[@]}"
else
    pass "offline verification complete; run with --online to verify GitHub attestations and keyless identities"
fi

printf '\nVerified airgap bundle %s\n' "${bundle}"
