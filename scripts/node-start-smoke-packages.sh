#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-output}
artifact_dir=$(cd "${artifact_dir}" && pwd)
report_path=${NODE_SMOKE_REPORT:-}

shopt -s nullglob
debs=("${artifact_dir}"/*.deb)
rpms=("${artifact_dir}"/*.rpm)

if [ "${#debs[@]}" -eq 0 ] && [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: no DEB or RPM artifacts found in ${artifact_dir}."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required for node start smoke tests."
    exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT

cat > "${tmp_dir}/node-start-smoke-inner.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

package_format=${1:?package format is required}
workdir=/tmp/k8s-node-smoke
pki_dir="${workdir}/pki"
mkdir -p "${workdir}" "${pki_dir}" /etc/kubernetes/pki /var/lib/kubelet

log() {
    printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

fail() {
    echo "ERROR: $*" >&2
    dump_logs
    exit 1
}

pids=()
names=()

dump_logs() {
    for log_file in "${workdir}"/*.log; do
        [ -f "${log_file}" ] || continue
        echo
        echo "===== $(basename "${log_file}") ====="
        tail -n 120 "${log_file}" || true
    done
}

cleanup_processes() {
    local pid
    for pid in "${pids[@]}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
}
trap cleanup_processes EXIT

install_packages() {
    case "${package_format}" in
        deb)
            log "Installing DEB package set"
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y \
                ca-certificates \
                conntrack \
                containerd \
                coreutils \
                curl \
                findutils \
                grep \
                iproute2 \
                iptables \
                openssl \
                procps \
                socat
            mapfile -t packages < <(find /packages -maxdepth 1 -type f -name '*.deb' ! -name '*certs*.deb' | sort)
            [ "${#packages[@]}" -gt 0 ] || fail "no non-certificate DEB packages found"
            apt-get install -y "${packages[@]}"
            ;;
        rpm)
            log "Installing RPM package set"
            dnf install -y \
                ca-certificates \
                conntrack-tools \
                coreutils \
                curl \
                findutils \
                grep \
                iproute \
                iptables \
                openssl \
                procps-ng \
                socat \
                systemd
            mapfile -t packages < <(find /packages -maxdepth 1 -type f -name '*.rpm' ! -name '*certs*.rpm' | sort)
            [ "${#packages[@]}" -gt 0 ] || fail "no non-certificate RPM packages found"
            dnf install -y "${packages[@]}"
            ;;
        *)
            fail "unsupported package format ${package_format}"
            ;;
    esac
}

b64() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w0 "$1"
    else
        base64 "$1" | tr -d '\n'
    fi
}

generate_pki() {
    log "Generating test PKI"
    openssl genrsa -out "${pki_dir}/ca.key" 2048
    openssl req -x509 -new -nodes -key "${pki_dir}/ca.key" -sha256 -days 2 \
        -subj "/CN=k8s-release-smoke-ca" \
        -out "${pki_dir}/ca.crt"

    cat > "${pki_dir}/apiserver.conf" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = kube-apiserver

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
IP.1 = 127.0.0.1
IP.2 = 10.96.0.1
EOF

    openssl genrsa -out "${pki_dir}/apiserver.key" 2048
    openssl req -new -key "${pki_dir}/apiserver.key" \
        -out "${pki_dir}/apiserver.csr" \
        -config "${pki_dir}/apiserver.conf"
    openssl x509 -req -in "${pki_dir}/apiserver.csr" \
        -CA "${pki_dir}/ca.crt" \
        -CAkey "${pki_dir}/ca.key" \
        -CAcreateserial \
        -out "${pki_dir}/apiserver.crt" \
        -days 2 \
        -sha256 \
        -extensions v3_req \
        -extfile "${pki_dir}/apiserver.conf"

    openssl genrsa -out "${pki_dir}/admin.key" 2048
    openssl req -new -key "${pki_dir}/admin.key" \
        -subj "/CN=smoke-admin/O=system:masters" \
        -out "${pki_dir}/admin.csr"
    openssl x509 -req -in "${pki_dir}/admin.csr" \
        -CA "${pki_dir}/ca.crt" \
        -CAkey "${pki_dir}/ca.key" \
        -CAcreateserial \
        -out "${pki_dir}/admin.crt" \
        -days 2 \
        -sha256

    openssl genrsa -out "${pki_dir}/sa.key" 2048
    openssl rsa -in "${pki_dir}/sa.key" -pubout -out "${pki_dir}/sa.pub"

    cp "${pki_dir}/ca.crt" /etc/kubernetes/pki/ca.crt
    cp "${pki_dir}/ca.key" /etc/kubernetes/pki/ca.key
}

write_kubeconfigs() {
    log "Writing kubeconfigs"
    local ca_crt admin_crt admin_key
    ca_crt=$(b64 "${pki_dir}/ca.crt")
    admin_crt=$(b64 "${pki_dir}/admin.crt")
    admin_key=$(b64 "${pki_dir}/admin.key")

    cat > "${workdir}/admin.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: smoke
  cluster:
    certificate-authority-data: ${ca_crt}
    server: https://127.0.0.1:6443
users:
- name: smoke-admin
  user:
    client-certificate-data: ${admin_crt}
    client-key-data: ${admin_key}
contexts:
- name: smoke
  context:
    cluster: smoke
    user: smoke-admin
current-context: smoke
EOF
    cp "${workdir}/admin.kubeconfig" "${workdir}/kubelet.kubeconfig"
}

start_process() {
    local name=$1
    shift
    log "Starting ${name}"
    "$@" > "${workdir}/${name}.log" 2>&1 &
    local pid=$!
    names+=("${name}")
    pids+=("${pid}")
    sleep 2
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
        fail "${name} exited during startup"
    fi
}

assert_processes_running() {
    local i name pid
    for i in "${!pids[@]}"; do
        name=${names[$i]}
        pid=${pids[$i]}
        if ! kill -0 "${pid}" >/dev/null 2>&1; then
            fail "${name} is not running"
        fi
    done
}

wait_for_command() {
    local description=$1
    shift
    local i
    for i in $(seq 1 90); do
        if "$@" >/tmp/k8s-node-smoke/wait.out 2>/tmp/k8s-node-smoke/wait.err; then
            cat /tmp/k8s-node-smoke/wait.out || true
            return 0
        fi
        sleep 2
    done
    echo "Last stdout:"
    cat /tmp/k8s-node-smoke/wait.out || true
    echo "Last stderr:"
    cat /tmp/k8s-node-smoke/wait.err || true
    fail "timed out waiting for ${description}"
}

wait_for_http() {
    local description=$1
    local url=$2
    shift 2
    wait_for_command "${description}" curl -fsS "$@" "${url}"
}

start_containerd_if_available() {
    if ! command -v containerd >/dev/null 2>&1; then
        log "containerd unavailable; kubelet process start will be skipped"
        return 1
    fi

    log "Starting containerd"
    mkdir -p /etc/containerd /run/containerd
    containerd config default > /etc/containerd/config.toml
    containerd > "${workdir}/containerd.log" 2>&1 &
    pids+=("$!")
    names+=("containerd")
    wait_for_command "containerd socket" test -S /run/containerd/containerd.sock
}

start_etcd() {
    start_process etcd \
        etcd \
        --name=default \
        --data-dir="${workdir}/etcd" \
        --listen-client-urls=http://127.0.0.1:2379 \
        --advertise-client-urls=http://127.0.0.1:2379 \
        --listen-peer-urls=http://127.0.0.1:2380 \
        --initial-advertise-peer-urls=http://127.0.0.1:2380 \
        --initial-cluster=default=http://127.0.0.1:2380 \
        --initial-cluster-state=new \
        --logger=zap \
        --log-level=warn
    wait_for_command "etcd health" etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
}

start_apiserver() {
    start_process kube-apiserver \
        kube-apiserver \
        --advertise-address=127.0.0.1 \
        --allow-privileged=true \
        --authorization-mode=Node,RBAC \
        --bind-address=127.0.0.1 \
        --client-ca-file="${pki_dir}/ca.crt" \
        --etcd-servers=http://127.0.0.1:2379 \
        --secure-port=6443 \
        --service-account-issuer=https://kubernetes.default.svc.cluster.local \
        --service-account-key-file="${pki_dir}/sa.pub" \
        --service-account-signing-key-file="${pki_dir}/sa.key" \
        --service-cluster-ip-range=10.96.0.0/12 \
        --tls-cert-file="${pki_dir}/apiserver.crt" \
        --tls-private-key-file="${pki_dir}/apiserver.key"
    wait_for_http "kube-apiserver readyz" \
        "https://127.0.0.1:6443/readyz" \
        --cacert "${pki_dir}/ca.crt" \
        --cert "${pki_dir}/admin.crt" \
        --key "${pki_dir}/admin.key"
    kubectl --kubeconfig="${workdir}/admin.kubeconfig" get --raw=/version
}

start_scheduler() {
    start_process kube-scheduler \
        kube-scheduler \
        --authentication-kubeconfig="${workdir}/admin.kubeconfig" \
        --authorization-kubeconfig="${workdir}/admin.kubeconfig" \
        --bind-address=127.0.0.1 \
        --kubeconfig="${workdir}/admin.kubeconfig" \
        --leader-elect=false
    wait_for_http "kube-scheduler healthz" "https://127.0.0.1:10259/healthz" -k
}

start_controller_manager() {
    start_process kube-controller-manager \
        kube-controller-manager \
        --allocate-node-cidrs=true \
        --authentication-kubeconfig="${workdir}/admin.kubeconfig" \
        --authorization-kubeconfig="${workdir}/admin.kubeconfig" \
        --bind-address=127.0.0.1 \
        --client-ca-file="${pki_dir}/ca.crt" \
        --cluster-cidr=10.244.0.0/16 \
        --cluster-name=kubernetes \
        --cluster-signing-cert-file="${pki_dir}/ca.crt" \
        --cluster-signing-key-file="${pki_dir}/ca.key" \
        --kubeconfig="${workdir}/admin.kubeconfig" \
        --leader-elect=false \
        --requestheader-client-ca-file="${pki_dir}/ca.crt" \
        --root-ca-file="${pki_dir}/ca.crt" \
        --service-account-private-key-file="${pki_dir}/sa.key" \
        --service-cluster-ip-range=10.96.0.0/12
    wait_for_http "kube-controller-manager healthz" "https://127.0.0.1:10257/healthz" -k
}

start_kube_proxy() {
    kubectl --kubeconfig="${workdir}/admin.kubeconfig" apply -f - <<'EOF'
apiVersion: v1
kind: Node
metadata:
  name: smoke-node
EOF

    cat > "${workdir}/kube-proxy-config.yaml" <<EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  kubeconfig: ${workdir}/admin.kubeconfig
clusterCIDR: 10.244.0.0/16
healthzBindAddress: 127.0.0.1:10256
hostnameOverride: smoke-node
metricsBindAddress: 127.0.0.1:10249
mode: iptables
EOF

    start_process kube-proxy kube-proxy --config="${workdir}/kube-proxy-config.yaml"
    wait_for_http "kube-proxy healthz" "http://127.0.0.1:10256/healthz"
}

start_kubelet_if_possible() {
    start_containerd_if_available || return 0

    cat > "${workdir}/kubelet-config.yaml" <<EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: true
authorization:
  mode: AlwaysAllow
cgroupDriver: cgroupfs
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
failSwapOn: false
healthzBindAddress: 127.0.0.1
healthzPort: 10248
readOnlyPort: 0
staticPodPath: ${workdir}/manifests
EOF
    mkdir -p "${workdir}/manifests" "${workdir}/kubelet-root" "${workdir}/kubelet-certs"

    start_process kubelet \
        kubelet \
        --cert-dir="${workdir}/kubelet-certs" \
        --config="${workdir}/kubelet-config.yaml" \
        --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
        --hostname-override=smoke-node \
        --kubeconfig="${workdir}/kubelet.kubeconfig" \
        --root-dir="${workdir}/kubelet-root" \
        --v=2
    wait_for_http "kubelet healthz" "http://127.0.0.1:10248/healthz"
}

verify_installed_binaries() {
    log "Verifying installed binaries"
    for bin in etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubectl kube-proxy; do
        command -v "${bin}" >/dev/null || fail "${bin} is not installed"
    done
    if command -v kubelet >/dev/null 2>&1; then
        kubelet --version
    fi
    kubectl version --client=true --output=yaml
}

install_packages
verify_installed_binaries
generate_pki
write_kubeconfigs
start_etcd
start_apiserver
start_scheduler
start_controller_manager
start_kube_proxy
start_kubelet_if_possible
assert_processes_running

log "Node start smoke test passed for ${package_format} packages"
INNER
chmod +x "${tmp_dir}/node-start-smoke-inner.sh"

run_in_node_container() {
    local image=$1
    local format=$2

    docker run --rm \
        --pull=always \
        --privileged \
        --cgroupns=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "${artifact_dir}:/packages:ro" \
        -v "${tmp_dir}:/smoke:ro" \
        "${image}" \
        bash /smoke/node-start-smoke-inner.sh "${format}"
}

run_smoke() {
    echo "Node start smoke test started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "${#debs[@]}" -gt 0 ]; then
        echo "Running node start smoke test for DEB packages in ubuntu:24.04"
        run_in_node_container ubuntu:24.04 deb
    fi

    if [ "${#rpms[@]}" -gt 0 ]; then
        echo "Running node start smoke test for RPM packages in rockylinux:9"
        run_in_node_container rockylinux:9 rpm
    fi

    echo "Node start smoke test passed for ${artifact_dir}."
}

if [ -n "${report_path}" ]; then
    mkdir -p "$(dirname "${report_path}")"
    run_smoke | tee "${report_path}"
else
    run_smoke
fi
