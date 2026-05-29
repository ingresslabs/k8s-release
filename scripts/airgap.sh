#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/airgap.sh prepare <version> [--artifacts DIR] [--repos DIR] [--output FILE] [--require-l4] [--require-upgrade]
  scripts/airgap.sh verify <bundle.tar> [--online] [--repo OWNER/REPO]
  scripts/airgap.sh import <bundle.tar> --repo DIR

Airgap import ceremony:
  prepare  Create the offline trust bundle.
  verify   Verify the bundle before import.
  import   Verify, extract, and copy the bundle into a local mirror directory.
EOF
}

command=${1:-}
case "${command}" in
    -h|--help|help|"")
        usage
        exit 0
        ;;
esac
shift

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

case "${command}" in
    prepare)
        version=${1:-}
        [ -n "${version}" ] || { usage >&2; exit 2; }
        shift
        exec ./scripts/create-airgap-bundle.sh "${version}" --airgap "$@"
        ;;
    verify)
        bundle=${1:-}
        [ -n "${bundle}" ] || { usage >&2; exit 2; }
        shift
        exec ./scripts/verify-bundle.sh "${bundle}" "$@"
        ;;
    import)
        bundle=
        mirror_dir=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --repo)
                    mirror_dir=${2:?--repo requires a directory}
                    shift 2
                    ;;
                --bundle)
                    bundle=${2:?--bundle requires a bundle path}
                    shift 2
                    ;;
                -h|--help)
                    usage
                    exit 0
                    ;;
                -*)
                    echo "ERROR: unknown argument '$1'." >&2
                    usage >&2
                    exit 2
                    ;;
                *)
                    if [ -z "${bundle}" ]; then
                        bundle=$1
                        shift
                    else
                        echo "ERROR: unexpected argument '$1'." >&2
                        usage >&2
                        exit 2
                    fi
                    ;;
            esac
        done

        [ -n "${bundle}" ] || fail "airgap import requires a bundle path"
        [ -n "${mirror_dir}" ] || fail "airgap import requires --repo DIR"
        [ -f "${bundle}" ] || fail "bundle not found: ${bundle}"

        tmp_dir=$(mktemp -d)
        cleanup() {
            rm -rf "${tmp_dir}"
        }
        trap cleanup EXIT

        ./scripts/verify-bundle.sh "${bundle}" --keep "${tmp_dir}/verified"
        root=$(find "${tmp_dir}/verified" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
        [ -n "${root}" ] || fail "verified bundle did not extract to a root directory"

        mkdir -p "${mirror_dir}"
        cp -a "${root}/." "${mirror_dir}/"
        (
            cd "${mirror_dir}"
            find . -type f -print0 | sort -z | xargs -0 sha256sum > IMPORT-SHA256SUMS
        )
        echo "Imported $(basename "${bundle}") into ${mirror_dir}."
        ;;
    *)
        echo "ERROR: unknown airgap command '${command}'." >&2
        usage >&2
        exit 2
        ;;
esac
