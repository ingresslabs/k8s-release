#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/verify-proof.sh <release-proof.json>

Verifies a replayable release proof without rerunning Docker or rebuilding
packages. The verifier checks proof signatures, evidence tar signatures, proof
status, gate status, and checksums for files that are present next to the proof.
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

proof=${1:-}
if [ -z "${proof}" ]; then
    usage >&2
    exit 2
fi

[ -f "${proof}" ] || { echo "ERROR: proof not found: ${proof}" >&2; exit 1; }
proof_dir=$(cd "$(dirname "${proof}")" && pwd)
proof="${proof_dir}/$(basename "${proof}")"

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

need_tool jq
need_tool sha256sum
need_tool gpg

key_file="${proof_dir}/release-proof-signing-key.asc"
proof_sig="${proof}.asc"
evidence_tar="${proof_dir}/release-evidence.tar"
evidence_sig="${evidence_tar}.asc"

[ -s "${key_file}" ] || fail "missing release-proof-signing-key.asc"
[ -s "${proof_sig}" ] || fail "missing proof signature: $(basename "${proof_sig}")"

gpg_home=$(mktemp -d)
cleanup() {
    rm -rf "${gpg_home}"
}
trap cleanup EXIT
chmod 700 "${gpg_home}"

log "Verifying release proof signature"
gpg --homedir "${gpg_home}" --batch --import "${key_file}" >/dev/null 2>&1
gpg --homedir "${gpg_home}" --batch --verify "${proof_sig}" "${proof}" >/dev/null 2>&1 ||
    fail "release proof signature verification failed"
pass "release proof signature verifies"

log "Checking proof schema and status"
jq -e '.schema_version == "k8s-release.proof.v1" and .status == "passed"' "${proof}" >/dev/null ||
    fail "invalid or failed release proof"
jq -e '(.gates | type == "array") and all(.gates[]; .status == "passed")' "${proof}" >/dev/null ||
    fail "one or more proof gates did not pass"
pass "proof schema and gates are valid"

verify_listed_checksums() {
    local jq_path=$1
    local label=$2
    local checked=0
    local name expected file actual

    while IFS=$'\t' read -r name expected; do
        [ -n "${name}" ] || continue
        file="${proof_dir}/${name}"
        if [ ! -f "${file}" ]; then
            printf 'WARN: %s listed but not present: %s\n' "${label}" "${name}" >&2
            continue
        fi
        actual=$(sha256sum "${file}" | awk '{print $1}')
        [ "${actual}" = "${expected}" ] || fail "${label} checksum mismatch for ${name}"
        checked=$((checked + 1))
    done < <(jq -r "${jq_path}[]? | [.name, .sha256] | @tsv" "${proof}")

    pass "${label} checksums verify (${checked} local files checked)"
}

verify_listed_checksums '.artifacts.package_checksums' packages
verify_listed_checksums '.artifacts.sbom_references' SBOM
verify_listed_checksums '.artifacts.release_manifests' manifests
verify_listed_checksums '.artifacts.evidence_reports' evidence

if [ -f "${evidence_tar}" ]; then
    [ -s "${evidence_sig}" ] || fail "missing evidence tar signature: $(basename "${evidence_sig}")"
    log "Verifying release evidence tar signature"
    gpg --homedir "${gpg_home}" --batch --verify "${evidence_sig}" "${evidence_tar}" >/dev/null 2>&1 ||
        fail "release evidence tar signature verification failed"
    pass "release evidence tar signature verifies"
fi

printf '\nVerified release proof %s\n' "${proof}"
