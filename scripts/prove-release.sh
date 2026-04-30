#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/prove-release.sh <version> --host HOST [options]

Runs the one-command Release Proof Engine. The command uploads the release
artifact set to a Linux proof host, runs L4 signed-repository, airgap, cluster
smoke, and optional upgrade checks, then fetches the machine-readable proof JSON
and human-readable reports back into the artifact directory.

Options:
  --artifacts DIR             Current release artifacts (default: release-artifacts)
  --repos DIR                 Current package repositories (default: package-repositories)
  --bundle FILE               Current airgap bundle (default: k8s-<version>-airgap.tar)
  --previous VERSION          Previous Kubernetes version for upgrade proof
  --previous-artifacts DIR    Previous release artifacts (default: release-artifacts-<previous>)
  --previous-repos DIR        Previous package repositories (default: package-repositories-<previous>)
  --previous-bundle FILE      Previous airgap bundle; used if previous dirs are absent
  --remote-dir DIR            Remote workspace (default: /tmp/k8s-release-proof-<version>-<timestamp>)
  --keep-remote               Leave the remote workspace in place

Example:
  k8s-release prove v1.32.2 --host Fourier --previous v1.32.1
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

host=
artifact_dir=release-artifacts
repo_dir=package-repositories
bundle=
previous_version=
previous_artifact_dir=
previous_repo_dir=
previous_bundle=
remote_dir=
keep_remote=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            host=${2:?--host requires an SSH host}
            shift 2
            ;;
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
        --remote-dir)
            remote_dir=${2:?--remote-dir requires a directory}
            shift 2
            ;;
        --keep-remote)
            keep_remote=1
            shift
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

[ -n "${host}" ] || { echo "ERROR: --host is required." >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

q() {
    local value=$1
    printf "'%s'" "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
}

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

need_tool ssh
need_tool scp
need_tool tar

bundle=$(find_bundle_candidate "${tag}" "${artifact_dir}" "${bundle}")
bundle_base=$(basename "${bundle}")

has_artifacts=0
has_repos=0
has_bundle=0
dir_has_packages "${artifact_dir}" && has_artifacts=1
[ -d "${repo_dir}" ] && has_repos=1
[ -f "${bundle}" ] && has_bundle=1

if [ "${has_artifacts}" -ne 1 ] || [ "${has_repos}" -ne 1 ]; then
    [ "${has_bundle}" -eq 1 ] || fail "current artifacts/repos are incomplete and no airgap bundle was found at ${bundle}"
fi

previous_tag=
previous_bundle_base=
if [ -n "${previous_version}" ]; then
    previous_tag=${previous_version}
    case "${previous_tag}" in
        v*) ;;
        *) previous_tag="v${previous_tag}" ;;
    esac
    previous_artifact_dir=${previous_artifact_dir:-release-artifacts-${previous_tag}}
    previous_repo_dir=${previous_repo_dir:-package-repositories-${previous_tag}}
    previous_bundle=$(find_bundle_candidate "${previous_tag}" "${previous_artifact_dir}" "${previous_bundle}")
    previous_bundle_base=$(basename "${previous_bundle}")

    previous_has_artifacts=0
    previous_has_repos=0
    previous_has_bundle=0
    dir_has_packages "${previous_artifact_dir}" && previous_has_artifacts=1
    [ -d "${previous_repo_dir}" ] && previous_has_repos=1
    [ -f "${previous_bundle}" ] && previous_has_bundle=1

    if [ "${previous_has_artifacts}" -ne 1 ] || [ "${previous_has_repos}" -ne 1 ]; then
        [ "${previous_has_bundle}" -eq 1 ] || fail "previous artifacts/repos are incomplete and no previous airgap bundle was found at ${previous_bundle}"
    fi
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ -z "${remote_dir}" ]; then
    remote_dir="/tmp/k8s-release-proof-${tag}-${timestamp}"
fi
remote_repo="${remote_dir}/repo"

cleanup_remote() {
    if [ "${keep_remote}" -eq 0 ]; then
        ssh -o BatchMode=yes "${host}" "rm -rf $(q "${remote_dir}")" >/dev/null 2>&1 || true
    fi
}
trap cleanup_remote EXIT

copy_dir_contents() {
    local source_dir=$1
    local remote_subdir=$2

    [ -d "${source_dir}" ] || return 0
    ssh -o BatchMode=yes "${host}" "mkdir -p $(q "${remote_repo}/${remote_subdir}")"
    scp -q -r "${source_dir}/." "${host}:${remote_repo}/${remote_subdir}/"
}

copy_file_if_present() {
    local source_file=$1
    local remote_name=$2

    [ -f "${source_file}" ] || return 0
    scp -q "${source_file}" "${host}:${remote_repo}/${remote_name}"
}

log "Checking proof host ${host}"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${host}" \
    'set -e; command -v docker >/dev/null; command -v tar >/dev/null; command -v sha256sum >/dev/null; command -v gpg >/dev/null; docker --version; docker compose version >/dev/null 2>&1 || true'

log "Uploading repository workspace to ${host}:${remote_repo}"
ssh -o BatchMode=yes "${host}" "rm -rf $(q "${remote_dir}") && mkdir -p $(q "${remote_repo}")"
tar \
    --exclude='.git' \
    --exclude='output' \
    --exclude='release-artifacts' \
    --exclude='release-artifacts-*' \
    --exclude='package-repositories' \
    --exclude='package-repositories-*' \
    --exclude='release-proof' \
    --exclude='k8s-*-airgap.tar' \
    -czf - . | ssh -o BatchMode=yes "${host}" "tar -xzf - -C $(q "${remote_repo}")"

log "Uploading current release proof inputs"
copy_dir_contents "${artifact_dir}" release-artifacts
copy_dir_contents "${repo_dir}" package-repositories
copy_file_if_present "${bundle}" "${bundle_base}"

if [ -n "${previous_tag}" ]; then
    log "Uploading previous release proof inputs for ${previous_tag}"
    copy_dir_contents "${previous_artifact_dir}" previous-release-artifacts
    copy_dir_contents "${previous_repo_dir}" previous-package-repositories
    copy_file_if_present "${previous_bundle}" "${previous_bundle_base}"
fi

log "Running remote release proof"
ssh -o BatchMode=yes "${host}" \
    "cd $(q "${remote_repo}") && TAG=$(q "${tag}") BUNDLE_BASE=$(q "${bundle_base}") PREVIOUS_TAG=$(q "${previous_tag}") PREVIOUS_BUNDLE_BASE=$(q "${previous_bundle_base}") HOST_LABEL=$(q "${host}") bash -se" <<'REMOTE_PROOF'
set -euo pipefail

extract_bundle_inputs() {
    local bundle=$1
    local artifacts=$2
    local repos=$3
    local tmp root

    [ -f "${bundle}" ] || { echo "ERROR: cannot extract missing bundle ${bundle}" >&2; exit 1; }
    tmp=$(mktemp -d)
    tar -xf "${bundle}" -C "${tmp}"
    root=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
    [ -n "${root}" ] || { echo "ERROR: bundle ${bundle} has no top-level directory" >&2; exit 1; }
    [ -d "${root}/release-artifacts" ] || { echo "ERROR: bundle ${bundle} is missing release-artifacts" >&2; exit 1; }
    [ -d "${root}/package-repositories" ] || { echo "ERROR: bundle ${bundle} is missing package-repositories" >&2; exit 1; }
    rm -rf "${artifacts}" "${repos}"
    cp -a "${root}/release-artifacts" "${artifacts}"
    cp -a "${root}/package-repositories" "${repos}"
    rm -rf "${tmp}"
}

dir_has_packages() {
    local dir=$1
    [ -d "${dir}" ] || return 1
    find "${dir}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' \) | grep -q .
}

if ! dir_has_packages release-artifacts || [ ! -d package-repositories ]; then
    extract_bundle_inputs "${BUNDLE_BASE}" release-artifacts package-repositories
fi

if [ ! -f "${BUNDLE_BASE}" ]; then
    ./scripts/create-airgap-bundle.sh "${TAG}" \
        --airgap \
        --artifacts release-artifacts \
        --repos package-repositories \
        --output "${BUNDLE_BASE}"
fi

previous_args=()
require_args=(--require-l4)
if [ -n "${PREVIOUS_TAG}" ]; then
    if ! dir_has_packages previous-release-artifacts || [ ! -d previous-package-repositories ]; then
        extract_bundle_inputs "${PREVIOUS_BUNDLE_BASE}" previous-release-artifacts previous-package-repositories
    fi
    previous_args=(
        --previous "${PREVIOUS_TAG}"
        --previous-artifacts previous-release-artifacts
        --previous-repos previous-package-repositories
    )
    require_args+=(--require-upgrade)
fi

./scripts/l4-release-proof.sh "${TAG}" \
    --artifacts release-artifacts \
    --repos package-repositories \
    --bundle "${BUNDLE_BASE}" \
    --output-dir release-artifacts \
    --host-label "${HOST_LABEL}" \
    "${previous_args[@]}"

KUBE_VERSION="${TAG}" ./scripts/generate-release-evidence.sh \
    release-artifacts \
    package-repositories \
    release-artifacts/release-evidence.md
cp package-repositories/repo-signing-key.asc release-artifacts/repo-signing-key.asc
./scripts/generate-release-passport.sh "${TAG}" \
    --artifacts release-artifacts \
    --repos package-repositories \
    --output release-artifacts/release-passport.md

./scripts/create-airgap-bundle.sh "${TAG}" \
    --airgap \
    --artifacts release-artifacts \
    --repos package-repositories \
    --output "release-artifacts/${BUNDLE_BASE}" \
    "${require_args[@]}"

./scripts/verify-bundle.sh "release-artifacts/${BUNDLE_BASE}"
REMOTE_PROOF

log "Fetching proof evidence into ${artifact_dir}"
mkdir -p "${artifact_dir}"
scp -q -r "${host}:${remote_repo}/release-artifacts/." "${artifact_dir}/"

if [ "${keep_remote}" -eq 1 ]; then
    log "Remote proof workspace preserved at ${host}:${remote_repo}"
fi

echo "Release proof completed for ${tag} on ${host}."
echo "Evidence directory: ${artifact_dir}"
