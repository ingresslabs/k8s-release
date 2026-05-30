#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/create-airgap-bundle.sh <version> [--airgap] [--artifacts DIR] [--repos DIR] [--output FILE] [--policy FILE] [--require-l4] [--require-upgrade]

Creates a self-contained offline bundle containing release artifacts, signed
package repositories, install helpers, a verification policy, and bundle-level
checksums.

Examples:
  scripts/create-airgap-bundle.sh v1.36.1 --airgap
  scripts/create-airgap-bundle.sh v1.36.1 --artifacts release-artifacts --repos package-repositories --output k8s-v1.36.1-airgap.tar
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
policy_file=
require_l4=0
require_upgrade=0
tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac
output_file="k8s-${tag}-airgap.tar"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --airgap)
            shift
            ;;
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
        --policy)
            policy_file=${2:?--policy requires a file}
            shift 2
            ;;
        --require-l4)
            require_l4=1
            shift
            ;;
        --require-upgrade)
            require_upgrade=1
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

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

[ -d "${artifact_dir}" ] || { echo "ERROR: artifact directory not found: ${artifact_dir}" >&2; exit 1; }
[ -d "${repo_dir}" ] || { echo "ERROR: package repository directory not found: ${repo_dir}" >&2; exit 1; }
[ -f "${artifact_dir}/SHA256SUMS" ] || { echo "ERROR: missing ${artifact_dir}/SHA256SUMS" >&2; exit 1; }
[ -f "${artifact_dir}/release-evidence.md" ] || { echo "ERROR: missing ${artifact_dir}/release-evidence.md" >&2; exit 1; }
[ -f "${repo_dir}/SHA256SUMS" ] || { echo "ERROR: missing ${repo_dir}/SHA256SUMS" >&2; exit 1; }
[ -s "${repo_dir}/repo-signing-key.asc" ] || { echo "ERROR: missing or empty ${repo_dir}/repo-signing-key.asc" >&2; exit 1; }

signed_metadata_count=$(
    {
        find "${repo_dir}/debian/dists" -type f -name Release.gpg 2>/dev/null || true
        find "${repo_dir}/rpm/repodata" -type f -name repomd.xml.asc 2>/dev/null || true
    } | wc -l | tr -d ' '
)
[ "${signed_metadata_count}" -gt 0 ] || { echo "ERROR: no signed apt/yum repository metadata found in ${repo_dir}" >&2; exit 1; }

if [ ! -f "${artifact_dir}/release-passport.md" ]; then
    ./scripts/generate-release-passport.sh "${tag}" \
        --artifacts "${artifact_dir}" \
        --repos "${repo_dir}" \
        --output "${artifact_dir}/release-passport.md"
fi

artifact_dir=$(cd "${artifact_dir}" && pwd)
repo_dir=$(cd "${repo_dir}" && pwd)
output_dir=$(dirname "${output_file}")
mkdir -p "${output_dir}"
output_file=$(cd "${output_dir}" && pwd)/$(basename "${output_file}")
rm -f "${output_file}"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

count_files() {
    local dir=$1
    local pattern=$2
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" | wc -l | tr -d ' '
}

json_bool() {
    if [ "$1" -eq 1 ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

if [ "${require_l4}" -eq 1 ] && [ "$(count_files "${artifact_dir}" '*-l4-smoke.txt')" -eq 0 ]; then
    echo "ERROR: --require-l4 was set but no *-l4-smoke.txt report exists in ${artifact_dir}" >&2
    exit 1
fi
if [ "${require_upgrade}" -eq 1 ] && [ "$(count_files "${artifact_dir}" '*-upgrade-smoke.txt')" -eq 0 ]; then
    echo "ERROR: --require-upgrade was set but no *-upgrade-smoke.txt report exists in ${artifact_dir}" >&2
    exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT

bundle_name="k8s-${tag}-airgap"
bundle_root="${tmp_dir}/${bundle_name}"
mkdir -p "${bundle_root}/metadata" "${bundle_root}/install"

cp -a "${artifact_dir}" "${bundle_root}/release-artifacts"
cp -a "${repo_dir}" "${bundle_root}/package-repositories"

if [ -n "${policy_file}" ]; then
    cp "${policy_file}" "${bundle_root}/metadata/verification-policy.json"
else
    cat > "${bundle_root}/metadata/verification-policy.json" <<EOF
{
  "schema_version": "k8s-release.verification-policy.v1",
  "kubernetes_version": "$(json_escape "${tag}")",
  "required": {
    "bundle_checksums": true,
    "release_artifact_checksums": true,
    "release_manifests": true,
    "spdx_sboms": true,
    "sigstore_bundles": true,
    "github_provenance": true,
    "signed_package_repositories": true,
    "release_evidence": true,
    "release_passport": true,
    "l4_cluster_smoke": $(json_bool "${require_l4}"),
    "upgrade_smoke": $(json_bool "${require_upgrade}")
  },
  "offline_verification": {
    "default_command": "./k8s-release verify-bundle ${bundle_name}.tar",
    "notes": "Offline verification checks local checksums, manifests, SBOM shape, signature files, repository metadata signatures, release evidence, and policy presence. Run verify-bundle --online in a connected environment to verify GitHub attestations and keyless Sigstore identities."
  }
}
EOF
fi

cat > "${bundle_root}/install/README.md" <<EOF
# ${tag} Airgap Install

This bundle contains Kubernetes package artifacts, signed local apt/yum
repositories, release evidence, a release passport, and verification policy.

Verify before import:

\`\`\`bash
./k8s-release verify-bundle ${bundle_name}.tar
\`\`\`

Use the local apt repository on Debian or Ubuntu:

\`\`\`bash
sudo ./install/setup-apt-repo.sh
sudo ./install/install-packages.sh
\`\`\`

Use the local yum repository on RPM-based systems:

\`\`\`bash
sudo ./install/setup-yum-repo.sh
sudo ./install/install-packages.sh
\`\`\`
EOF

cat > "${bundle_root}/install/setup-apt-repo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bundle_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir="${bundle_dir}/package-repositories/debian"
key_file="${bundle_dir}/package-repositories/repo-signing-key.asc"
codename=${REPO_CODENAME:-stable}
keyring=/usr/share/keyrings/k8s-release-airgap.gpg
source_list=/etc/apt/sources.list.d/k8s-release-airgap.list

[ -d "${repo_dir}" ] || { echo "ERROR: missing Debian repository: ${repo_dir}" >&2; exit 1; }
[ -f "${key_file}" ] || { echo "ERROR: missing repository signing key: ${key_file}" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "ERROR: gpg is required to configure apt keyring." >&2; exit 1; }

gpg --dearmor < "${key_file}" > "${keyring}"
chmod 0644 "${keyring}"
printf 'deb [signed-by=%s] file:%s %s main\n' "${keyring}" "${repo_dir}" "${codename}" > "${source_list}"
apt-get update
echo "Configured ${source_list}."
EOF

cat > "${bundle_root}/install/setup-yum-repo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bundle_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir="${bundle_dir}/package-repositories/rpm"
key_file="${bundle_dir}/package-repositories/repo-signing-key.asc"
repo_file=/etc/yum.repos.d/k8s-release-airgap.repo

[ -d "${repo_dir}" ] || { echo "ERROR: missing RPM repository: ${repo_dir}" >&2; exit 1; }
[ -f "${key_file}" ] || { echo "ERROR: missing repository signing key: ${key_file}" >&2; exit 1; }
mkdir -p "$(dirname "${repo_file}")"
cat > "${repo_file}" <<REPO
[k8s-release-airgap]
name=Kubernetes airgap packages
baseurl=file://${repo_dir}
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file://${key_file}
REPO
if command -v dnf >/dev/null 2>&1; then
    dnf makecache --disablerepo='*' --enablerepo=k8s-release-airgap
elif command -v yum >/dev/null 2>&1; then
    yum makecache --disablerepo='*' --enablerepo=k8s-release-airgap
else
    echo "ERROR: dnf or yum is required." >&2
    exit 1
fi
echo "Configured ${repo_file}."
EOF

cat > "${bundle_root}/install/install-packages.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

packages=("$@")
if [ "${#packages[@]}" -eq 0 ]; then
    bundle_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    artifact_dir="${bundle_dir}/release-artifacts"
    if command -v apt-get >/dev/null 2>&1; then
        mapfile -t packages < <(find "${artifact_dir}" -maxdepth 1 -type f -name '*.deb' -exec dpkg-deb --field {} Package \; | sort -u)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        mapfile -t packages < <(find "${artifact_dir}" -maxdepth 1 -type f -name '*.rpm' -exec rpm -qp --queryformat '%{NAME}\n' {} \; | sort -u)
    fi
    [ "${#packages[@]}" -gt 0 ] || { echo "ERROR: could not infer packages from ${artifact_dir}" >&2; exit 1; }
fi

if command -v apt-get >/dev/null 2>&1; then
    "$(dirname -- "${BASH_SOURCE[0]}")/setup-apt-repo.sh"
    apt-get install -y "${packages[@]}"
elif command -v dnf >/dev/null 2>&1; then
    "$(dirname -- "${BASH_SOURCE[0]}")/setup-yum-repo.sh"
    dnf install -y --disablerepo='*' --enablerepo=k8s-release-airgap "${packages[@]}"
elif command -v yum >/dev/null 2>&1; then
    "$(dirname -- "${BASH_SOURCE[0]}")/setup-yum-repo.sh"
    yum install -y --disablerepo='*' --enablerepo=k8s-release-airgap "${packages[@]}"
else
    echo "ERROR: apt-get, dnf, or yum is required." >&2
    exit 1
fi
EOF

chmod +x "${bundle_root}/install/"*.sh

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_repo=${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null || echo local)}
source_ref=${GITHUB_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}
source_commit=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
project_version=$(cat VERSION 2>/dev/null || echo unknown)

cat > "${bundle_root}/metadata/bundle-manifest.json" <<EOF
{
  "schema_version": "k8s-release.airgap-bundle.v1",
  "generated_at": "$(json_escape "${generated_at}")",
  "kubernetes_version": "$(json_escape "${tag}")",
  "project_version": "$(json_escape "${project_version}")",
  "source": {
    "repository": "$(json_escape "${source_repo}")",
    "ref": "$(json_escape "${source_ref}")",
    "commit": "$(json_escape "${source_commit}")"
  },
  "contents": {
    "packages": $(($(count_files "${bundle_root}/release-artifacts" '*.deb') + $(count_files "${bundle_root}/release-artifacts" '*.rpm'))),
    "spdx_sboms": $(count_files "${bundle_root}/release-artifacts" '*.spdx.json'),
    "sigstore_bundles": $(count_files "${bundle_root}/release-artifacts" '*.sigstore.json'),
    "release_manifests": $(count_files "${bundle_root}/release-artifacts" '*-release-manifest.json'),
    "install_smoke_reports": $(count_files "${bundle_root}/release-artifacts" '*-install-smoke.txt'),
    "node_start_smoke_reports": $(count_files "${bundle_root}/release-artifacts" '*-node-start-smoke.txt'),
    "l4_smoke_reports": $(count_files "${bundle_root}/release-artifacts" '*-l4-smoke.txt'),
    "upgrade_smoke_reports": $(count_files "${bundle_root}/release-artifacts" '*-upgrade-smoke.txt'),
    "release_proofs": $(($(count_files "${bundle_root}/release-artifacts" '*-release-proof.json') + $(count_files "${bundle_root}/release-artifacts" 'release-proof.json')))
  },
  "verification": {
    "offline_command": "./k8s-release verify-bundle $(basename "${output_file}")",
    "online_command": "./k8s-release verify-bundle $(basename "${output_file}") --online"
  }
}
EOF

(
    cd "${bundle_root}"
    find . -type f ! -path './metadata/BUNDLE-SHA256SUMS' -print0 |
        sort -z |
        xargs -0 sha256sum > metadata/BUNDLE-SHA256SUMS
)

(
    cd "${tmp_dir}"
    tar -cf "${output_file}" "${bundle_name}"
)

echo "Wrote ${output_file}."
