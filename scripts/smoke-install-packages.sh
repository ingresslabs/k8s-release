#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-output}
artifact_dir=$(cd "${artifact_dir}" && pwd)
report_path=${SMOKE_REPORT:-}

shopt -s nullglob
debs=("${artifact_dir}"/*.deb)
rpms=("${artifact_dir}"/*.rpm)

if [ "${#debs[@]}" -eq 0 ] && [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: no DEB or RPM artifacts found in ${artifact_dir}."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required for install smoke tests."
    exit 1
fi

run_in_container() {
    local image=$1
    local script=$2

    docker run --rm \
        --pull=always \
        -v "${artifact_dir}:/packages:ro" \
        "${image}" \
        bash -euo pipefail -c "${script}"
}

all_are_cert_packages() {
    local pkg
    for pkg in "$@"; do
        case "$(basename "$pkg")" in
            *certs*.deb|*certs*.rpm)
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 0
}

common_checks='
smoke_binary() {
    bin=$1
    name=$(basename "$bin")
    echo "Smoke testing ${name}"
    case "$name" in
        kubectl)
            timeout 20s "$bin" version --client=true >/dev/null 2>&1 || timeout 20s "$bin" --help >/dev/null
            ;;
        etcd|etcdctl|kube-apiserver|kube-controller-manager|kube-proxy|kube-scheduler|kubelet|flanneld|calico-node|calico-felix|calico-kube-controllers)
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

if [ -d /usr/local/bin ]; then
    found=0
    for bin in /usr/local/bin/*; do
        [ -x "$bin" ] || continue
        found=1
        smoke_binary "$bin"
    done
    if [ "$found" -eq 0 ]; then
        echo "No executable payloads under /usr/local/bin; treating as data-only package set."
    fi
fi

for unit in \
    /lib/systemd/system/kube*.service \
    /lib/systemd/system/etcd.service \
    /lib/systemd/system/flanneld.service \
    /lib/systemd/system/calico*.service \
    /usr/lib/systemd/system/kube*.service \
    /usr/lib/systemd/system/etcd.service \
    /usr/lib/systemd/system/flanneld.service \
    /usr/lib/systemd/system/calico*.service; do
    [ -f "$unit" ] || continue
    echo "Validating systemd unit $(basename "$unit")"
    grep -q "^ExecStart=" "$unit"
done

if [ -d /etc/kubernetes ] || [ -d /var/lib/kubelet ]; then
    for dir in /etc/kubernetes /var/lib/kubelet; do
        [ -d "$dir" ] || continue
        find "$dir" -type f
    done | sort
fi
'

run_smoke() {
    echo "Install smoke test started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "${#debs[@]}" -gt 0 ]; then
        if all_are_cert_packages "${debs[@]}"; then
            for deb in "${debs[@]}"; do
                deb_name=$(basename "${deb}")
                echo "Testing DEB install path for ${deb_name} in ubuntu:24.04"
                run_in_container ubuntu:24.04 "
                    export DEBIAN_FRONTEND=noninteractive
                    apt-get update
                    apt-get install -y ca-certificates coreutils findutils grep systemd
                    apt-get install -y /packages/${deb_name}
                    dpkg-query -W -f='\${Package} \${Version} \${Architecture}\n' | grep -E '^(kube|etcd|flannel|calico|kubernetes-)' || true
                    ${common_checks}
                "
            done
        else
            echo "Testing DEB install path in ubuntu:24.04"
            run_in_container ubuntu:24.04 "
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y ca-certificates coreutils findutils grep systemd
                apt-get install -y /packages/*.deb
                dpkg-query -W -f='\${Package} \${Version} \${Architecture}\n' | grep -E '^(kube|etcd|flannel|calico|kubernetes-)' || true
                ${common_checks}
            "
        fi
    fi

    if [ "${#rpms[@]}" -gt 0 ]; then
        if all_are_cert_packages "${rpms[@]}"; then
            for rpm in "${rpms[@]}"; do
                rpm_name=$(basename "${rpm}")
                echo "Testing RPM install path for ${rpm_name} in rockylinux:9"
                run_in_container rockylinux:9 "
                    dnf install -y findutils grep systemd
                    dnf install -y /packages/${rpm_name}
                    rpm -qa | grep -E '^(kube|etcd|flannel|calico|kubernetes-)' || true
                    ${common_checks}
                "
            done
        else
            echo "Testing RPM install path in rockylinux:9"
            run_in_container rockylinux:9 "
                dnf install -y findutils grep systemd
                dnf install -y /packages/*.rpm
                rpm -qa | grep -E '^(kube|etcd|flannel|calico|kubernetes-)' || true
                ${common_checks}
            "
        fi
    fi

    echo "Install smoke test passed for ${artifact_dir}."
}

if [ -n "${report_path}" ]; then
    run_smoke | tee "${report_path}"
else
    run_smoke
fi
