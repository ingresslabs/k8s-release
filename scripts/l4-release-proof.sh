#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/l4-release-proof.sh <version> --artifacts DIR --repos DIR --bundle FILE [options]

Runs the L4 release proof on the current host. The proof verifies the airgap
bundle, installs from signed package repositories, installs from the airgap
bundle, starts the packaged control-plane components, and optionally proves an
upgrade from a previous artifact set.

Options:
  --previous VERSION          Previous Kubernetes version for upgrade proof
  --previous-artifacts DIR    Previous release artifact directory
  --previous-repos DIR        Previous package repository directory
  --output-dir DIR            Evidence output directory (default: artifact dir)
  --host-label NAME           Label used in evidence file names
  --cluster-smoke-backend MODE  Cluster smoke backend: local or k2vm (default: local)
  --cluster-smoke-host HOST     Remote SSH host for k2vm cluster smoke
  --cluster-smoke-remote-dir DIR  Remote working directory for k2vm cluster smoke
  --keep-cluster-smoke-remote  Keep the remote k2vm working directory after success
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

artifact_dir=
repo_dir=
bundle=
previous_version=
previous_artifact_dir=
previous_repo_dir=
output_dir=
host_label=${HOSTNAME:-local}
cluster_smoke_backend=local
cluster_smoke_host=
cluster_smoke_remote_dir=
keep_cluster_smoke_remote=0

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
        --output-dir)
            output_dir=${2:?--output-dir requires a directory}
            shift 2
            ;;
        --host-label)
            host_label=${2:?--host-label requires a name}
            shift 2
            ;;
        --cluster-smoke-backend)
            cluster_smoke_backend=${2:?--cluster-smoke-backend requires a mode}
            shift 2
            ;;
        --cluster-smoke-host)
            cluster_smoke_host=${2:?--cluster-smoke-host requires a host}
            shift 2
            ;;
        --cluster-smoke-remote-dir)
            cluster_smoke_remote_dir=${2:?--cluster-smoke-remote-dir requires a directory}
            shift 2
            ;;
        --keep-cluster-smoke-remote)
            keep_cluster_smoke_remote=1
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

[ -n "${artifact_dir}" ] || { echo "ERROR: --artifacts is required." >&2; exit 2; }
[ -n "${repo_dir}" ] || { echo "ERROR: --repos is required." >&2; exit 2; }
[ -n "${bundle}" ] || { echo "ERROR: --bundle is required." >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac

if [ -n "${previous_version}" ]; then
    previous_tag=${previous_version}
    case "${previous_tag}" in
        v*) ;;
        *) previous_tag="v${previous_tag}" ;;
    esac
    [ -n "${previous_artifact_dir}" ] || { echo "ERROR: --previous-artifacts is required when --previous is set." >&2; exit 2; }
    [ -n "${previous_repo_dir}" ] || { echo "ERROR: --previous-repos is required when --previous is set." >&2; exit 2; }
else
    previous_tag=
fi

[ -d "${artifact_dir}" ] || { echo "ERROR: artifact directory not found: ${artifact_dir}" >&2; exit 1; }
[ -d "${repo_dir}" ] || { echo "ERROR: package repository directory not found: ${repo_dir}" >&2; exit 1; }
[ -f "${bundle}" ] || { echo "ERROR: airgap bundle not found: ${bundle}" >&2; exit 1; }

case "${cluster_smoke_backend}" in
    local|k2vm) ;;
    *)
        echo "ERROR: --cluster-smoke-backend must be local or k2vm." >&2
        exit 2
        ;;
esac
if [ "${cluster_smoke_backend}" = "k2vm" ] && [ -z "${cluster_smoke_host}" ]; then
    echo "ERROR: --cluster-smoke-host is required when --cluster-smoke-backend=k2vm." >&2
    exit 2
fi

artifact_dir=$(cd "${artifact_dir}" && pwd)
repo_dir=$(cd "${repo_dir}" && pwd)
bundle=$(cd "$(dirname "${bundle}")" && pwd)/$(basename "${bundle}")
if [ -n "${previous_artifact_dir}" ]; then
    [ -d "${previous_artifact_dir}" ] || { echo "ERROR: previous artifact directory not found: ${previous_artifact_dir}" >&2; exit 1; }
    previous_artifact_dir=$(cd "${previous_artifact_dir}" && pwd)
fi
if [ -n "${previous_repo_dir}" ]; then
    [ -d "${previous_repo_dir}" ] || { echo "ERROR: previous package repository directory not found: ${previous_repo_dir}" >&2; exit 1; }
    previous_repo_dir=$(cd "${previous_repo_dir}" && pwd)
fi

if [ -z "${output_dir}" ]; then
    output_dir=${artifact_dir}
fi
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

safe_host=$(safe_name "${host_label}")
proof_json="${output_dir}/${tag}-${safe_host}-release-proof.json"
l4_report="${output_dir}/${tag}-${safe_host}-l4-smoke.txt"
airgap_verify_report="${output_dir}/${tag}-${safe_host}-airgap-verify.txt"
signed_repo_report="${output_dir}/${tag}-${safe_host}-signed-repo-install.txt"
airgap_install_report="${output_dir}/${tag}-${safe_host}-airgap-install.txt"
upgrade_report="${output_dir}/${tag}-${safe_host}-upgrade-smoke.txt"

generated_at=$(utc_now)
host_name=$(hostname 2>/dev/null || echo unknown)
kernel=$(uname -a 2>/dev/null || echo unknown)
os_name=unknown
if [ -r /etc/os-release ]; then
    os_name=$(awk -F= '/^PRETTY_NAME=/ {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
fi
docker_version=$(docker --version 2>/dev/null || echo unavailable)

gate_names=()
gate_statuses=()
gate_reports=()
gate_seconds=()

write_json() {
    local status=$1
    local finished_at=$2

    {
        printf '{\n'
        printf '  "schema_version": "k8s-release.release-proof.v1",\n'
        printf '  "status": "%s",\n' "$(json_escape "${status}")"
        printf '  "generated_at": "%s",\n' "$(json_escape "${generated_at}")"
        printf '  "finished_at": "%s",\n' "$(json_escape "${finished_at}")"
        printf '  "kubernetes_version": "%s",\n' "$(json_escape "${tag}")"
        if [ -n "${previous_tag}" ]; then
            printf '  "previous_version": "%s",\n' "$(json_escape "${previous_tag}")"
        else
            printf '  "previous_version": null,\n'
        fi
        printf '  "host": {\n'
        printf '    "label": "%s",\n' "$(json_escape "${host_label}")"
        printf '    "hostname": "%s",\n' "$(json_escape "${host_name}")"
        printf '    "os": "%s",\n' "$(json_escape "${os_name}")"
        printf '    "kernel": "%s",\n' "$(json_escape "${kernel}")"
        printf '    "docker": "%s"\n' "$(json_escape "${docker_version}")"
        printf '  },\n'
        printf '  "inputs": {\n'
        printf '    "artifacts": "%s",\n' "$(json_escape "${artifact_dir}")"
        printf '    "repositories": "%s",\n' "$(json_escape "${repo_dir}")"
        printf '    "airgap_bundle": "%s"\n' "$(json_escape "${bundle}")"
        printf '  },\n'
        printf '  "cluster_smoke": {\n'
        printf '    "backend": "%s",\n' "$(json_escape "${cluster_smoke_backend}")"
        if [ -n "${cluster_smoke_host}" ]; then
            printf '    "target": "%s",\n' "$(json_escape "${cluster_smoke_host}")"
        else
            printf '    "target": null,\n'
        fi
        if [ -n "${cluster_smoke_remote_dir}" ]; then
            printf '    "remote_dir": "%s",\n' "$(json_escape "${cluster_smoke_remote_dir}")"
        else
            printf '    "remote_dir": null,\n'
        fi
        printf '    "keep_remote": %s\n' "$( [ "${keep_cluster_smoke_remote}" -eq 1 ] && printf true || printf false )"
        printf '  },\n'
        printf '  "evidence": {\n'
        printf '    "l4_smoke_report": "%s",\n' "$(json_escape "$(basename "${l4_report}")")"
        if [ -n "${previous_tag}" ]; then
            printf '    "upgrade_smoke_report": "%s",\n' "$(json_escape "$(basename "${upgrade_report}")")"
        else
            printf '    "upgrade_smoke_report": null,\n'
        fi
        printf '    "proof_json": "%s"\n' "$(json_escape "$(basename "${proof_json}")")"
        printf '  },\n'
        printf '  "gates": [\n'
        local i comma
        for i in "${!gate_names[@]}"; do
            comma=","
            if [ "$((i + 1))" -eq "${#gate_names[@]}" ]; then
                comma=""
            fi
            printf '    {"name": "%s", "status": "%s", "report": "%s", "seconds": %s}%s\n' \
                "$(json_escape "${gate_names[$i]}")" \
                "$(json_escape "${gate_statuses[$i]}")" \
                "$(json_escape "$(basename "${gate_reports[$i]}")")" \
                "${gate_seconds[$i]}" \
                "${comma}"
        done
        printf '  ]\n'
        printf '}\n'
    } > "${proof_json}"
}

record_gate() {
    gate_names+=("$1")
    gate_statuses+=("$2")
    gate_reports+=("$3")
    gate_seconds+=("$4")
}

run_gate() {
    local name=$1
    local report=$2
    shift 2

    local start end rc status
    start=$(date +%s)
    set +e
    (
        printf 'Gate: %s\n' "${name}"
        printf 'Started: %s\n' "$(utc_now)"
        printf 'Host: %s (%s)\n' "${host_label}" "${host_name}"
        printf '\n'
        "$@"
        rc=$?
        printf '\nFinished: %s\n' "$(utc_now)"
        exit "${rc}"
    ) > "${report}" 2>&1
    rc=$?
    set -e
    end=$(date +%s)

    if [ "${rc}" -eq 0 ]; then
        status=passed
    else
        status=failed
    fi

    record_gate "${name}" "${status}" "${report}" "$((end - start))"
    write_json "${status}" "$(utc_now)"

    if [ "${rc}" -ne 0 ]; then
        echo "ERROR: ${name} failed. Last report lines:" >&2
        tail -n 80 "${report}" >&2 || true
        exit "${rc}"
    fi
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: $1 is required for L4 proof." >&2
        exit 1
    }
}

smoke_installed_payloads='
smoke_binary() {
    bin=$1
    name=$(basename "$bin")
    echo "Smoke testing ${name}"
    case "$name" in
        kubectl)
            timeout 20s "$bin" version --client=true >/dev/null 2>&1 || timeout 20s "$bin" --help >/dev/null
            ;;
        istioctl)
            timeout 20s "$bin" version --remote=false >/dev/null 2>&1 || timeout 20s "$bin" version >/dev/null 2>&1 || timeout 20s "$bin" --help >/dev/null
            ;;
        calico-node)
            timeout 20s "$bin" -v >/dev/null
            ;;
        etcd|etcdctl|kube-apiserver|kube-controller-manager|kube-proxy|kube-scheduler|kubelet|flanneld|calico-felix|calico-kube-controllers)
            timeout 20s "$bin" --version >/dev/null 2>&1 || timeout 20s "$bin" --help >/dev/null
            ;;
        calico|calico-ipam)
            echo "Verified executable CNI plugin ${name}"
            ;;
        *)
            timeout 20s "$bin" --version >/dev/null 2>&1 || timeout 20s "$bin" --help >/dev/null 2>&1 || true
            ;;
    esac
}

found=0
if [ -d /usr/local/bin ]; then
    for bin in /usr/local/bin/*; do
        [ -x "$bin" ] || continue
        found=1
        smoke_binary "$bin"
    done
fi
[ "$found" -eq 1 ] || { echo "ERROR: no installed executable payloads found under /usr/local/bin" >&2; exit 1; }
'

run_deb_repo_install_smoke() {
    docker run --rm \
        --pull=always \
        -v "${artifact_dir}:/artifacts:ro" \
        -v "${repo_dir}:/repo:ro" \
        ubuntu:24.04 \
        bash -euo pipefail -s <<INNER
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates coreutils findutils gnupg grep systemd
install -d -m 0755 /usr/share/keyrings
gpg --dearmor < /repo/repo-signing-key.asc > /usr/share/keyrings/k8s-release.gpg
chmod 0644 /usr/share/keyrings/k8s-release.gpg
printf 'deb [signed-by=/usr/share/keyrings/k8s-release.gpg] file:/repo/debian stable main\n' > /etc/apt/sources.list.d/k8s-release.list
apt-get update
mapfile -t packages < <(find /artifacts -maxdepth 1 -type f -name '*.deb' -exec dpkg-deb --field {} Package \; | sort -u)
[ "\${#packages[@]}" -gt 0 ] || { echo "ERROR: no DEB packages found" >&2; exit 1; }
printf 'Installing from signed apt repository: %s\n' "\${packages[*]}"
apt-get install -y "\${packages[@]}"
dpkg-query -W -f='\${Package} \${Version} \${Architecture}\n' "\${packages[@]}" | sort
${smoke_installed_payloads}
INNER
}

run_rpm_repo_install_smoke() {
    docker run --rm \
        --pull=always \
        -v "${artifact_dir}:/artifacts:ro" \
        -v "${repo_dir}:/repo:ro" \
        rockylinux:9 \
        bash -euo pipefail -s <<INNER
dnf install -y findutils grep systemd
mkdir -p /etc/yum.repos.d
cat > /etc/yum.repos.d/k8s-release.repo <<'REPO'
[k8s-release]
name=Kubernetes release proof packages
baseurl=file:///repo/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///repo/repo-signing-key.asc
REPO
dnf makecache --disablerepo='*' --enablerepo=k8s-release
mapfile -t packages < <(find /artifacts -maxdepth 1 -type f -name '*.rpm' -exec rpm -qp --queryformat '%{NAME}\n' {} \; | sort -u)
[ "\${#packages[@]}" -gt 0 ] || { echo "ERROR: no RPM packages found" >&2; exit 1; }
printf 'Installing from signed yum repository: %s\n' "\${packages[*]}"
dnf install -y --disablerepo='*' --enablerepo=k8s-release "\${packages[@]}"
rpm -q "\${packages[@]}" | sort
${smoke_installed_payloads}
INNER
}

signed_repo_install_smoke() {
    local ran=0

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
        [ -d "${repo_dir}/debian" ] || { echo "ERROR: Debian repository missing from ${repo_dir}" >&2; exit 1; }
        echo "Running signed apt repository install smoke"
        run_deb_repo_install_smoke
        ran=1
    fi

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.rpm' | grep -q .; then
        [ -d "${repo_dir}/rpm" ] || { echo "ERROR: RPM repository missing from ${repo_dir}" >&2; exit 1; }
        echo "Running signed yum repository install smoke"
        run_rpm_repo_install_smoke
        ran=1
    fi

    [ "${ran}" -eq 1 ] || { echo "ERROR: no DEB or RPM artifacts found for signed repository smoke" >&2; exit 1; }
}

run_deb_airgap_install_smoke() {
    local bundle_root=$1

    docker run --rm \
        --pull=always \
        -v "${bundle_root}:/bundle:ro" \
        ubuntu:24.04 \
        bash -euo pipefail -s <<INNER
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates coreutils findutils gnupg grep systemd
cd /bundle
./install/install-packages.sh
${smoke_installed_payloads}
INNER
}

run_rpm_airgap_install_smoke() {
    local bundle_root=$1

    docker run --rm \
        --pull=always \
        -v "${bundle_root}:/bundle:ro" \
        rockylinux:9 \
        bash -euo pipefail -s <<INNER
dnf install -y findutils grep systemd
cd /bundle
./install/install-packages.sh
${smoke_installed_payloads}
INNER
}

airgap_install_smoke() {
    local tmp_dir bundle_root ran=0
    tmp_dir=$(mktemp -d)
    tar -xf "${bundle}" -C "${tmp_dir}"
    bundle_root=$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
    [ -n "${bundle_root}" ] || { echo "ERROR: airgap bundle did not extract to a root directory" >&2; exit 1; }

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
        echo "Running airgap bundle install smoke in Ubuntu"
        run_deb_airgap_install_smoke "${bundle_root}"
        ran=1
    fi

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.rpm' | grep -q .; then
        echo "Running airgap bundle install smoke in Rocky Linux"
        run_rpm_airgap_install_smoke "${bundle_root}"
        ran=1
    fi

    [ "${ran}" -eq 1 ] || { echo "ERROR: no DEB or RPM artifacts found for airgap smoke" >&2; exit 1; }
    rm -rf "${tmp_dir}"
}

cluster_conformance_smoke() {
    case "${cluster_smoke_backend}" in
        local)
            echo "Running packaged control-plane conformance smoke on the local host"
            ./scripts/node-start-smoke-packages.sh "${artifact_dir}"
            ;;
        k2vm)
            local args=(
                "${tag}"
                --host "${cluster_smoke_host}"
                --artifacts "${artifact_dir}"
                --repos "${repo_dir}"
                --output-dir "${output_dir}"
            )
            if [ -n "${cluster_smoke_remote_dir}" ]; then
                args+=(--remote-dir "${cluster_smoke_remote_dir}")
            fi
            if [ "${keep_cluster_smoke_remote}" -eq 1 ]; then
                args+=(--keep-remote)
            fi
            echo "Running packaged control-plane conformance smoke on remote k2vm host ${cluster_smoke_host}"
            ./scripts/k2vm-cluster-smoke.sh "${args[@]}"
            ;;
    esac
}

airgap_bundle_gate() {
    need_tool docker
    need_tool tar
    need_tool sha256sum
    need_tool gpg

    echo "Verifying airgap bundle offline"
    ./scripts/verify-bundle.sh "${bundle}"
}

run_deb_upgrade_smoke() {
    docker run --rm \
        --pull=always \
        -v "${previous_artifact_dir}:/previous-artifacts:ro" \
        -v "${previous_repo_dir}:/previous-repo:ro" \
        -v "${artifact_dir}:/current-artifacts:ro" \
        -v "${repo_dir}:/current-repo:ro" \
        ubuntu:24.04 \
        bash -euo pipefail -s "${previous_tag#v}" "${tag#v}" <<INNER
previous_version=\$1
current_version=\$2
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates coreutils findutils gnupg grep systemd
install -d -m 0755 /usr/share/keyrings
gpg --dearmor < /previous-repo/repo-signing-key.asc > /usr/share/keyrings/k8s-release.gpg
chmod 0644 /usr/share/keyrings/k8s-release.gpg
printf 'deb [signed-by=/usr/share/keyrings/k8s-release.gpg] file:/previous-repo/debian stable main\n' > /etc/apt/sources.list.d/k8s-release.list
apt-get update
mapfile -t previous_packages < <(find /previous-artifacts -maxdepth 1 -type f -name '*.deb' -exec dpkg-deb --field {} Package \; | sort -u)
[ "\${#previous_packages[@]}" -gt 0 ] || { echo "ERROR: no previous DEB packages found" >&2; exit 1; }
apt-get install -y "\${previous_packages[@]}"
dpkg-query -W -f='previous \${Package} \${Version} \${Architecture}\n' "\${previous_packages[@]}" | sort

gpg --dearmor < /current-repo/repo-signing-key.asc > /usr/share/keyrings/k8s-release.gpg.new
mv /usr/share/keyrings/k8s-release.gpg.new /usr/share/keyrings/k8s-release.gpg
printf 'deb [signed-by=/usr/share/keyrings/k8s-release.gpg] file:/current-repo/debian stable main\n' > /etc/apt/sources.list.d/k8s-release.list
apt-get update
mapfile -t current_packages < <(find /current-artifacts -maxdepth 1 -type f -name '*.deb' -exec dpkg-deb --field {} Package \; | sort -u)
[ "\${#current_packages[@]}" -gt 0 ] || { echo "ERROR: no current DEB packages found" >&2; exit 1; }
apt-get install -y "\${current_packages[@]}"
dpkg-query -W -f='current \${Package} \${Version} \${Architecture}\n' "\${current_packages[@]}" | sort
if printf '%s\n' "\${current_packages[@]}" | grep -qx kubelet; then
    installed=\$(dpkg-query -W -f='\${Version}' kubelet)
    case "\${installed}" in
        "\${current_version}"*) ;;
        *) echo "ERROR: kubelet upgraded to \${installed}, expected \${current_version}" >&2; exit 1 ;;
    esac
fi
${smoke_installed_payloads}

echo "Rolling back to previous apt repository"
gpg --dearmor < /previous-repo/repo-signing-key.asc > /usr/share/keyrings/k8s-release.gpg.previous
mv /usr/share/keyrings/k8s-release.gpg.previous /usr/share/keyrings/k8s-release.gpg
printf 'deb [signed-by=/usr/share/keyrings/k8s-release.gpg] file:/previous-repo/debian stable main\n' > /etc/apt/sources.list.d/k8s-release.list
apt-get update
apt-get install -y --allow-downgrades "\${previous_packages[@]}"
dpkg-query -W -f='rollback \${Package} \${Version} \${Architecture}\n' "\${previous_packages[@]}" | sort
if printf '%s\n' "\${previous_packages[@]}" | grep -qx kubelet; then
    installed=\$(dpkg-query -W -f='\${Version}' kubelet)
    case "\${installed}" in
        "\${previous_version}"*) ;;
        *) echo "ERROR: kubelet rolled back to \${installed}, expected \${previous_version}" >&2; exit 1 ;;
    esac
fi
${smoke_installed_payloads}
INNER
}

run_rpm_upgrade_smoke() {
    docker run --rm \
        --pull=always \
        -v "${previous_artifact_dir}:/previous-artifacts:ro" \
        -v "${previous_repo_dir}:/previous-repo:ro" \
        -v "${artifact_dir}:/current-artifacts:ro" \
        -v "${repo_dir}:/current-repo:ro" \
        rockylinux:9 \
        bash -euo pipefail -s "${previous_tag#v}" "${tag#v}" <<INNER
previous_version=\$1
current_version=\$2
dnf install -y findutils grep systemd
mkdir -p /etc/yum.repos.d
cat > /etc/yum.repos.d/k8s-release.repo <<'REPO'
[k8s-release]
name=Kubernetes release proof packages
baseurl=file:///previous-repo/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///previous-repo/repo-signing-key.asc
REPO
dnf makecache --disablerepo='*' --enablerepo=k8s-release
mapfile -t previous_packages < <(find /previous-artifacts -maxdepth 1 -type f -name '*.rpm' -exec rpm -qp --queryformat '%{NAME}\n' {} \; | sort -u)
[ "\${#previous_packages[@]}" -gt 0 ] || { echo "ERROR: no previous RPM packages found" >&2; exit 1; }
dnf install -y --disablerepo='*' --enablerepo=k8s-release "\${previous_packages[@]}"
rpm -q "\${previous_packages[@]}" | sed 's/^/previous /' | sort

cat > /etc/yum.repos.d/k8s-release.repo <<'REPO'
[k8s-release]
name=Kubernetes release proof packages
baseurl=file:///current-repo/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///current-repo/repo-signing-key.asc
REPO
dnf clean all
dnf makecache --disablerepo='*' --enablerepo=k8s-release
mapfile -t current_packages < <(find /current-artifacts -maxdepth 1 -type f -name '*.rpm' -exec rpm -qp --queryformat '%{NAME}\n' {} \; | sort -u)
[ "\${#current_packages[@]}" -gt 0 ] || { echo "ERROR: no current RPM packages found" >&2; exit 1; }
dnf install -y --disablerepo='*' --enablerepo=k8s-release "\${current_packages[@]}"
rpm -q "\${current_packages[@]}" | sed 's/^/current /' | sort
if printf '%s\n' "\${current_packages[@]}" | grep -qx kubelet; then
    installed=\$(rpm -q --queryformat '%{VERSION}' kubelet)
    case "\${installed}" in
        "\${current_version}"*) ;;
        *) echo "ERROR: kubelet upgraded to \${installed}, expected \${current_version}" >&2; exit 1 ;;
    esac
fi
${smoke_installed_payloads}

echo "Rolling back to previous yum repository"
cat > /etc/yum.repos.d/k8s-release.repo <<'REPO'
[k8s-release]
name=Kubernetes release proof packages
baseurl=file:///previous-repo/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///previous-repo/repo-signing-key.asc
REPO
dnf clean all
dnf makecache --disablerepo='*' --enablerepo=k8s-release
dnf downgrade -y --allowerasing --disablerepo='*' --enablerepo=k8s-release "\${previous_packages[@]}"
rpm -q "\${previous_packages[@]}" | sed 's/^/rollback /' | sort
if printf '%s\n' "\${previous_packages[@]}" | grep -qx kubelet; then
    installed=\$(rpm -q --queryformat '%{VERSION}' kubelet)
    case "\${installed}" in
        "\${previous_version}"*) ;;
        *) echo "ERROR: kubelet rolled back to \${installed}, expected \${previous_version}" >&2; exit 1 ;;
    esac
fi
${smoke_installed_payloads}
INNER
}

upgrade_smoke_gate() {
    local ran=0

    [ -n "${previous_tag}" ] || { echo "ERROR: previous version is required for upgrade smoke" >&2; exit 1; }
    [ -d "${previous_artifact_dir}" ] || { echo "ERROR: previous artifact directory not found: ${previous_artifact_dir}" >&2; exit 1; }
    [ -d "${previous_repo_dir}" ] || { echo "ERROR: previous package repository directory not found: ${previous_repo_dir}" >&2; exit 1; }

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.deb' | grep -q . && \
       find "${previous_artifact_dir}" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
        echo "Running DEB upgrade smoke from ${previous_tag} to ${tag}"
        run_deb_upgrade_smoke
        ran=1
    fi

    if find "${artifact_dir}" -maxdepth 1 -type f -name '*.rpm' | grep -q . && \
       find "${previous_artifact_dir}" -maxdepth 1 -type f -name '*.rpm' | grep -q .; then
        echo "Running RPM upgrade smoke from ${previous_tag} to ${tag}"
        run_rpm_upgrade_smoke
        ran=1
    fi

    [ "${ran}" -eq 1 ] || { echo "ERROR: no matching current and previous package formats found for upgrade smoke" >&2; exit 1; }
}

write_json running ""
run_gate airgap_bundle_verify "${airgap_verify_report}" airgap_bundle_gate
run_gate signed_repo_install "${signed_repo_report}" signed_repo_install_smoke
run_gate airgap_install "${airgap_install_report}" airgap_install_smoke
run_gate cluster_smoke "${l4_report}" cluster_conformance_smoke

if [ -n "${previous_tag}" ]; then
    run_gate upgrade_rollback_smoke "${upgrade_report}" upgrade_smoke_gate
fi

write_json passed "$(utc_now)"
echo "Wrote ${proof_json}."
