#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/generate-release-passport.sh <version> [--artifacts DIR] [--repos DIR] [--output FILE]

Writes a human-readable release passport with install commands, checksums,
SBOM/provenance/signature inventory, tested OS matrix, and L4 evidence status.
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

artifact_dir=release-artifacts
repo_dir=package-repositories
output_file=
tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac

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
        --output)
            output_file=${2:?--output requires a file}
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

[ -d "${artifact_dir}" ] || { echo "ERROR: artifact directory not found: ${artifact_dir}" >&2; exit 1; }
[ -d "${repo_dir}" ] || { echo "ERROR: package repository directory not found: ${repo_dir}" >&2; exit 1; }

artifact_dir=$(cd "${artifact_dir}" && pwd)
repo_dir=$(cd "${repo_dir}" && pwd)
if [ -z "${output_file}" ]; then
    output_file="${artifact_dir}/release-passport.md"
fi
mkdir -p "$(dirname "${output_file}")"

count_files() {
    local dir=$1
    local pattern=$2
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" | wc -l | tr -d ' '
}

list_files() {
    local dir=$1
    local pattern=$2
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" -exec basename {} \; 2>/dev/null | sort
}

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_repo=${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null || echo local)}
source_ref=${GITHUB_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}
source_commit=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
workflow_run=
if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    workflow_run="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

has_deb=0
has_rpm=0
[ "$(count_files "${artifact_dir}" '*.deb')" -gt 0 ] && has_deb=1
[ "$(count_files "${artifact_dir}" '*.rpm')" -gt 0 ] && has_rpm=1

l4_reports=$(list_files "${artifact_dir}" '*-l4-smoke.txt' || true)
upgrade_reports=$(list_files "${artifact_dir}" '*-upgrade-smoke.txt' || true)
proof_reports=$(
    {
        list_files "${artifact_dir}" '*-release-proof.json' || true
        list_files "${artifact_dir}" 'release-proof.json' || true
    } | sort -u
)
node_reports=$(list_files "${artifact_dir}" '*-node-start-smoke.txt' || true)
install_reports=$(list_files "${artifact_dir}" '*-install-smoke.txt' || true)

{
    echo "# ${tag} Release Passport"
    echo
    echo "Generated: ${generated_at}"
    echo
    echo "## Source"
    echo
    echo "- Repository: ${source_repo}"
    echo "- Ref: ${source_ref}"
    echo "- Commit: ${source_commit}"
    if [ -n "${workflow_run}" ]; then
        echo "- Workflow run: ${workflow_run}"
    fi
    echo
    echo "## Install From Signed Repository"
    echo
    if [ "${has_deb}" -eq 1 ]; then
        echo "Debian or Ubuntu:"
        echo
        echo '```bash'
        echo "sudo install -m 0644 package-repositories/repo-signing-key.asc /usr/share/keyrings/k8s-release.asc"
        echo "printf 'deb [signed-by=/usr/share/keyrings/k8s-release.asc] file:%s stable main\\n' \"\$(pwd)/package-repositories/debian\" | sudo tee /etc/apt/sources.list.d/k8s-release.list"
        echo "sudo apt-get update"
        echo "packages=\$(find release-artifacts -maxdepth 1 -name '*.deb' ! -name '*certs*.deb' -exec dpkg-deb --field {} Package \\; | sort -u | tr '\\n' ' ')"
        echo "sudo apt-get install -y \${packages}"
        echo '```'
        echo
    fi
    if [ "${has_rpm}" -eq 1 ]; then
        echo "RPM-based systems:"
        echo
        echo '```bash'
        echo "sudo tee /etc/yum.repos.d/k8s-release.repo >/dev/null <<'REPO'"
        echo "[k8s-release]"
        echo "name=Kubernetes packages"
        echo "baseurl=file://\$(pwd)/package-repositories/rpm"
        echo "enabled=1"
        echo "gpgcheck=0"
        echo "repo_gpgcheck=1"
        echo "gpgkey=file://\$(pwd)/package-repositories/repo-signing-key.asc"
        echo "REPO"
        echo "packages=\$(find release-artifacts -maxdepth 1 -name '*.rpm' ! -name '*certs*.rpm' -exec rpm -qp --queryformat '%{NAME}\\n' {} \\; | sort -u | tr '\\n' ' ')"
        echo "sudo dnf install -y \${packages}"
        echo '```'
        echo
    fi
    echo "Airgap bundle:"
    echo
    echo '```bash'
    echo "./k8s-release bundle ${tag} --airgap"
    echo "./k8s-release verify-bundle k8s-${tag}-airgap.tar"
    echo "tar -xf k8s-${tag}-airgap.tar"
    echo "cd k8s-${tag}-airgap"
    echo "sudo ./install/install-packages.sh"
    echo '```'
    echo
    echo "## Verification Inventory"
    echo
    echo "|Evidence|Count|"
    echo "|---|---:|"
    echo "|Packages|$(($(count_files "${artifact_dir}" '*.deb') + $(count_files "${artifact_dir}" '*.rpm')))|"
    echo "|SPDX SBOMs|$(count_files "${artifact_dir}" '*.spdx.json')|"
    echo "|Sigstore bundles|$(count_files "${artifact_dir}" '*.sigstore.json')|"
    echo "|Release manifests|$(count_files "${artifact_dir}" '*-release-manifest.json')|"
    echo "|Install smoke reports|$(count_files "${artifact_dir}" '*-install-smoke.txt')|"
    echo "|Node start smoke reports|$(count_files "${artifact_dir}" '*-node-start-smoke.txt')|"
    echo "|L4 cluster smoke reports|$(count_files "${artifact_dir}" '*-l4-smoke.txt')|"
    echo "|Upgrade smoke reports|$(count_files "${artifact_dir}" '*-upgrade-smoke.txt')|"
    echo "|Release proof JSON|$(($(count_files "${artifact_dir}" '*-release-proof.json') + $(count_files "${artifact_dir}" 'release-proof.json')))|"
    echo
    echo "## Package Checksums"
    echo
    if [ -f "${artifact_dir}/SHA256SUMS" ]; then
        echo '```text'
        cat "${artifact_dir}/SHA256SUMS"
        echo '```'
    else
        echo "No SHA256SUMS file found."
    fi
    echo
    echo "## SBOMs, Signatures, And Provenance"
    echo
    for file in $(list_files "${artifact_dir}" '*.spdx.json'); do
        echo "- SBOM: ${file}"
    done
    for file in $(list_files "${artifact_dir}" '*.sigstore.json'); do
        echo "- Sigstore bundle: ${file}"
    done
    for file in $(list_files "${artifact_dir}" '*-release-manifest.json'); do
        echo "- Release manifest: ${file}"
    done
    for file in $(list_files "${artifact_dir}" '*-release-proof.json'); do
        echo "- Release proof: ${file}"
    done
    if [ -f "${artifact_dir}/release-proof.json" ]; then
        echo "- Release proof: release-proof.json"
    fi
    if [ -f "${artifact_dir}/release-evidence.tar" ]; then
        echo "- Release evidence archive: release-evidence.tar"
    fi
    echo "- GitHub provenance: verified with \`./k8s-release verify-release ${tag}\` when online."
    echo
    echo "## Supported OS Matrix"
    echo
    echo "|Package format|Smoke image|Repository path|"
    echo "|---|---|---|"
    if [ "${has_deb}" -eq 1 ]; then
        echo "|DEB|ubuntu:24.04|package-repositories/debian|"
    fi
    if [ "${has_rpm}" -eq 1 ]; then
        echo "|RPM|rockylinux:9|package-repositories/rpm|"
    fi
    echo
    echo "## Rebuild And Runtime Evidence"
    echo
    echo "- Rebuild proof: deterministic packages are gated by the \`compare-reproducibility\` workflow job."
    if [ -n "${install_reports}" ]; then
        while IFS= read -r report; do
            [ -n "${report}" ] && echo "- Install smoke: ${report}"
        done <<< "${install_reports}"
    fi
    if [ -n "${node_reports}" ]; then
        while IFS= read -r report; do
            [ -n "${report}" ] && echo "- Node start smoke: ${report}"
        done <<< "${node_reports}"
    fi
    if [ -n "${l4_reports}" ]; then
        while IFS= read -r report; do
            [ -n "${report}" ] && echo "- L4 cluster smoke: ${report}"
        done <<< "${l4_reports}"
    else
        echo "- L4 cluster smoke: no report found in this artifact set."
    fi
    if [ -n "${upgrade_reports}" ]; then
        while IFS= read -r report; do
            [ -n "${report}" ] && echo "- Upgrade smoke: ${report}"
        done <<< "${upgrade_reports}"
    else
        echo "- Upgrade smoke: no report found in this artifact set."
    fi
    echo
    echo "## Verification Commands"
    echo
    echo '```bash'
    echo "./k8s-release verify-release ${tag}"
    echo "./k8s-release verify-bundle k8s-${tag}-airgap.tar"
    echo "./k8s-release verify-bundle k8s-${tag}-airgap.tar --online"
    echo '```'
} > "${output_file}"

echo "Wrote ${output_file}."
