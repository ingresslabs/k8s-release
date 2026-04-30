#!/usr/bin/env bash
set -euo pipefail

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
  --previous VERSION          Previous Kubernetes version for upgrade proof
  --previous-artifacts DIR    Previous release artifacts (default: release-artifacts-<previous>)
  --previous-repos DIR        Previous package repositories (default: package-repositories-<previous>)
  --previous-bundle FILE      Previous airgap bundle; used if previous dirs are absent

Example:
  k8s-release prove v1.32.2 --previous v1.32.1
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
        --host|--remote-dir|--keep-remote)
            echo "ERROR: release proof runs locally only; remote proof hosts are not supported." >&2
            usage >&2
            exit 2
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

need_tool docker
need_tool tar
need_tool sha256sum
need_tool gpg

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "${tmp_dir}"
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

previous_tag=
previous_args=()
require_args=(--require-l4)
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

log "Running local release proof for ${tag}"
./scripts/l4-release-proof.sh "${tag}" \
    --artifacts "${work_artifact_dir}" \
    --repos "${work_repo_dir}" \
    --bundle "${bundle}" \
    --output-dir "${work_artifact_dir}" \
    --host-label local \
    "${previous_args[@]}"

ensure_release_evidence "${work_artifact_dir}" "${work_repo_dir}"
./scripts/generate-release-passport.sh "${tag}" \
    --artifacts "${work_artifact_dir}" \
    --repos "${work_repo_dir}" \
    --output "${work_artifact_dir}/release-passport.md"

log "Creating proof-enforced airgap bundle"
./scripts/create-airgap-bundle.sh "${tag}" \
    --airgap \
    --artifacts "${work_artifact_dir}" \
    --repos "${work_repo_dir}" \
    --output "${work_artifact_dir}/$(basename "${bundle}")" \
    "${require_args[@]}"

./scripts/verify-bundle.sh "${work_artifact_dir}/$(basename "${bundle}")"

mkdir -p "${artifact_dir}"
cp -a "${work_artifact_dir}/." "${artifact_dir}/"

echo "Release proof completed locally for ${tag}."
echo "Evidence directory: ${artifact_dir}"
