#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-release-artifacts}
repo_dir=${2:-package-repositories}
output_file=${3:-release-evidence.md}

artifact_dir=$(cd "${artifact_dir}" && pwd)
repo_dir=$(cd "${repo_dir}" 2>/dev/null && pwd || true)

value_from_makefile() {
    local key=$1
    awk -v key="${key}" '$1 == key && $2 == "?=" {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' Makefile
}

count_files() {
    local pattern=$1
    find "${artifact_dir}" -maxdepth 1 -type f -name "${pattern}" | wc -l | tr -d ' '
}

{
    echo "# Release Evidence"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Source"
    echo
    echo "- Repository: ${GITHUB_REPOSITORY:-local}"
    echo "- Ref: ${GITHUB_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}"
    echo "- Commit: ${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
    if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
        echo "- Workflow run: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    echo
    echo "## Component Versions"
    echo
    echo "- Kubernetes: ${KUBE_VERSION:-$(value_from_makefile KUBE_VERSION)}"
    echo "- etcd: ${ETCD_VERSION:-$(value_from_makefile ETCD_VERSION)}"
    echo "- Flannel: ${FLANNEL_VERSION:-$(value_from_makefile FLANNEL_VERSION)}"
    echo "- Calico: ${CALICO_VERSION:-$(value_from_makefile CALICO_VERSION)}"
    echo "- Istio: ${ISTIO_VERSION:-$(value_from_makefile ISTIO_VERSION)}"
    echo
    echo "## Build Inputs"
    echo
    echo "- KUBE_GO_IMAGE: ${KUBE_GO_IMAGE:-$(value_from_makefile KUBE_GO_IMAGE)}"
    echo "- ETCD_GO_IMAGE: ${ETCD_GO_IMAGE:-$(value_from_makefile ETCD_GO_IMAGE)}"
    echo "- FLANNEL_GO_IMAGE: ${FLANNEL_GO_IMAGE:-$(value_from_makefile FLANNEL_GO_IMAGE)}"
    echo "- CALICO_GO_IMAGE: ${CALICO_GO_IMAGE:-$(value_from_makefile CALICO_GO_IMAGE)}"
    echo "- RUNTIME_IMAGE: ${RUNTIME_IMAGE:-$(value_from_makefile RUNTIME_IMAGE)}"
    echo "- DEBIAN_SNAPSHOT: ${DEBIAN_SNAPSHOT:-$(value_from_makefile DEBIAN_SNAPSHOT)}"
    echo "- SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH:-}"
    echo
    echo "## Evidence"
    echo
    echo "- Packages: $(($(count_files '*.deb') + $(count_files '*.rpm')))"
    echo "- SPDX SBOMs: $(count_files '*.spdx.json')"
    echo "- Sigstore bundles: $(count_files '*.sigstore.json')"
    echo "- Component manifests: $(count_files '*-release-manifest.json')"
    echo "- Install smoke reports: $(count_files '*-install-smoke.txt')"
    echo "- Node start smoke reports: $(count_files '*-node-start-smoke.txt')"
    if [ -n "${repo_dir}" ] && [ -f "${repo_dir}/repo-signing-key.asc" ]; then
        echo "- Signed package repository key: package-repositories/repo-signing-key.asc"
    fi
    echo
    echo "## Checksums"
    echo
    if [ -f "${artifact_dir}/SHA256SUMS" ]; then
        echo '```text'
        cat "${artifact_dir}/SHA256SUMS"
        echo '```'
    else
        echo "No combined checksum file found."
    fi
} > "${output_file}"

echo "Wrote ${output_file}."
