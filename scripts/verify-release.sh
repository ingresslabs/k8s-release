#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/verify-release.sh <version> [--repo OWNER/REPO] [--dir DIR]

Verifies a release asset set by checking:
  - SHA256SUMS and release manifests
  - SPDX SBOM JSON
  - Sigstore blob signatures
  - GitHub provenance attestations
  - source ref, source commit, and GitHub Actions workflow identity

Examples:
  k8s-release verify-release v1.36.1
  k8s-release verify-release v1.36.1 --repo kubekattle/k8s-release
  k8s-release verify-release v1.36.1 --dir release-artifacts
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
    usage
    exit 2
fi
shift

repo=${GITHUB_REPOSITORY:-}
artifact_dir=
issuer=https://token.actions.githubusercontent.com
identity_regexp=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            repo=${2:?--repo requires OWNER/REPO}
            shift 2
            ;;
        --dir)
            artifact_dir=${2:?--dir requires a directory}
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

log() {
    printf '==> %s\n' "$*"
}

pass() {
    printf 'PASS: %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required for release verification"
}

default_repo() {
    local remote
    remote=$(git remote get-url origin 2>/dev/null || true)
    case "${remote}" in
        https://github.com/*/*.git)
            remote=${remote#https://github.com/}
            printf '%s\n' "${remote%.git}"
            ;;
        git@github.com:*.git)
            remote=${remote#git@github.com:}
            printf '%s\n' "${remote%.git}"
            ;;
    esac
}

if [ -z "${repo}" ]; then
    repo=$(default_repo)
fi
[ -n "${repo}" ] || fail "repository is required; pass --repo OWNER/REPO"

tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac

tmp_dir=
cleanup() {
    if [ -n "${tmp_dir}" ]; then
        rm -rf "${tmp_dir}"
    fi
}
trap cleanup EXIT

if [ -z "${artifact_dir}" ]; then
    need_tool gh
    tmp_dir=$(mktemp -d)
    artifact_dir="${tmp_dir}/release-artifacts"
    mkdir -p "${artifact_dir}"
    log "Downloading ${repo}@${tag} release assets"
    gh release download "${tag}" --repo "${repo}" --dir "${artifact_dir}" --pattern '*' --clobber
else
    artifact_dir=$(cd "${artifact_dir}" && pwd)
fi

if [ -z "${identity_regexp}" ]; then
    identity_regexp="https://github\\.com/${repo}/\\.github/workflows/(build|release|publish-packages)\\.yml@refs/(heads|tags)/.*"
fi

shopt -s nullglob
packages=("${artifact_dir}"/*.deb "${artifact_dir}"/*.rpm)
sboms=("${artifact_dir}"/*.spdx.json)
manifest_candidates=("${artifact_dir}"/*-release-manifest.json "${artifact_dir}"/release-manifest.json)
manifests=()
for manifest in "${manifest_candidates[@]}"; do
    [ -f "${manifest}" ] && manifests+=("${manifest}")
done

[ "${#packages[@]}" -gt 0 ] || fail "no DEB/RPM packages found in ${artifact_dir}"

find_asset() {
    local raw_path=$1
    local base
    base=$(basename "${raw_path}")

    if [ -f "${raw_path}" ]; then
        printf '%s\n' "${raw_path}"
    elif [ -f "${artifact_dir}/${raw_path}" ]; then
        printf '%s\n' "${artifact_dir}/${raw_path}"
    elif [ -f "${artifact_dir}/${base}" ]; then
        printf '%s\n' "${artifact_dir}/${base}"
    else
        return 1
    fi
}

verify_checksum_file() {
    local checksum_file="${artifact_dir}/SHA256SUMS"
    local line expected raw_path candidate actual checked=0

    [ -f "${checksum_file}" ] || fail "missing SHA256SUMS"
    need_tool sha256sum

    log "Verifying SHA256SUMS"
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        expected=$(printf '%s\n' "${line}" | awk '{print $1}')
        raw_path=$(printf '%s\n' "${line}" | sed -E 's/^[0-9a-fA-F]{64}[[:space:]]+[*]?//')
        [ -n "${expected}" ] && [ -n "${raw_path}" ] || fail "invalid checksum line: ${line}"
        candidate=$(find_asset "${raw_path}") || fail "checksum target not found: ${raw_path}"
        actual=$(sha256sum "${candidate}" | awk '{print $1}')
        [ "${actual}" = "${expected}" ] || fail "checksum mismatch for ${raw_path}"
        checked=$((checked + 1))
    done < "${checksum_file}"

    [ "${checked}" -gt 0 ] || fail "SHA256SUMS has no entries"
    pass "checksums match (${checked} files)"
}

verify_manifests() {
    local manifest name expected candidate actual checked=0

    [ "${#manifests[@]}" -gt 0 ] || fail "missing release manifest JSON"
    need_tool jq
    need_tool sha256sum

    log "Verifying release manifests"
    for manifest in "${manifests[@]}"; do
        jq -e '.artifacts | type == "array" and length > 0' "${manifest}" >/dev/null || fail "invalid manifest: ${manifest}"
        while IFS=$'\t' read -r name expected; do
            [ -n "${name}" ] && [ -n "${expected}" ] || fail "invalid artifact entry in ${manifest}"
            candidate=$(find_asset "${name}") || fail "manifest target not found: ${name}"
            actual=$(sha256sum "${candidate}" | awk '{print $1}')
            [ "${actual}" = "${expected}" ] || fail "manifest checksum mismatch for ${name}"
            checked=$((checked + 1))
        done < <(jq -r '.artifacts[] | [.name, .sha256] | @tsv' "${manifest}")
    done

    pass "release manifests match (${checked} artifact entries)"
}

verify_sboms() {
    local sbom

    [ "${#sboms[@]}" -gt 0 ] || fail "missing SPDX SBOM files"
    need_tool jq

    log "Verifying SPDX SBOMs"
    for sbom in "${sboms[@]}"; do
        jq -e '.spdxVersion and .SPDXID and (.packages | type == "array")' "${sbom}" >/dev/null || fail "invalid SPDX SBOM: ${sbom}"
    done

    pass "SPDX SBOMs parse (${#sboms[@]} files)"
}

verify_evidence() {
    local evidence="${artifact_dir}/release-evidence.md"

    [ -f "${evidence}" ] || fail "missing release-evidence.md"
    grep -F -- "- Repository: ${repo}" "${evidence}" >/dev/null || fail "release evidence does not name ${repo}"
    grep -F -- "- Kubernetes: ${tag}" "${evidence}" >/dev/null || fail "release evidence does not name Kubernetes ${tag}"
    grep -F -- "https://github.com/${repo}/actions/runs/" "${evidence}" >/dev/null || fail "release evidence does not link a GitHub Actions run"

    source_ref=$(awk -F': ' '/^- Ref:/ {print $2; exit}' "${evidence}")
    source_commit=$(awk -F': ' '/^- Commit:/ {print $2; exit}' "${evidence}")
    [ -n "${source_ref}" ] || fail "release evidence is missing source ref"
    [ -n "${source_commit}" ] || fail "release evidence is missing source commit"

    pass "release evidence names source ref, commit, workflow run, and version"
}

verify_sigstore_bundles() {
    local pkg bundle

    need_tool cosign
    log "Verifying Sigstore blob signatures"
    for pkg in "${packages[@]}"; do
        bundle="${pkg}.sigstore.json"
        [ -f "${bundle}" ] || fail "missing Sigstore bundle for $(basename "${pkg}")"
        cosign verify-blob \
            --bundle "${bundle}" \
            --certificate-identity-regexp "${identity_regexp}" \
            --certificate-oidc-issuer "${issuer}" \
            "${pkg}" >/dev/null
    done

    pass "Sigstore signatures match GitHub workflow identity (${#packages[@]} packages)"
}

verify_github_attestations() {
    local pkg args=()

    need_tool gh
    log "Verifying GitHub provenance attestations"
    for pkg in "${packages[@]}"; do
        args=(
            attestation verify "${pkg}"
            --repo "${repo}"
            --predicate-type https://slsa.dev/provenance/v1
            --cert-identity-regex "${identity_regexp}"
            --cert-oidc-issuer "${issuer}"
        )
        if [ -n "${source_ref:-}" ]; then
            args+=(--source-ref "${source_ref}")
        fi
        if printf '%s\n' "${source_commit:-}" | grep -Eq '^[0-9a-fA-F]{40}$'; then
            args+=(--source-digest "${source_commit}")
        fi
        gh "${args[@]}" >/dev/null
    done

    pass "GitHub provenance and source identity verified (${#packages[@]} packages)"
}

verify_checksum_file
verify_manifests
verify_sboms
verify_evidence
verify_sigstore_bundles
verify_github_attestations

printf '\nVerified %s release %s from %s\n' "${repo}" "${tag}" "${artifact_dir}"
