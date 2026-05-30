#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-apply}"

RUN_ROOT="${RUN_ROOT:-/var/lib/k2vm-k3s}"
CACHE_ROOT="${CACHE_ROOT:-/var/cache/k2vm-k3s}"
SERVER_COUNT="${SERVER_COUNT:-1}"
AGENT_COUNT="${AGENT_COUNT:-2}"
NODE_COUNT="$((SERVER_COUNT + AGENT_COUNT))"

SUBNET_PREFIX="${SUBNET_PREFIX:-172.31.240}"
BRIDGE_NAME="${BRIDGE_NAME:-k2vmk3s240}"
TAP_PREFIX="${TAP_PREFIX:-k2vmk3s240}"
FIRECRACKER_BIN="${FIRECRACKER_BIN:-/usr/local/bin/firecracker}"
BASE_ROOTFS="${BASE_ROOTFS:-/opt/firecracker-sandbox-lab/rootfs.ext4}"
KERNEL_PATH="${KERNEL_PATH:-/opt/firecracker-sandbox-lab/vmlinux.bin}"
DEFAULT_KERNEL_BOOT_ARGS="${DEFAULT_KERNEL_BOOT_ARGS:-console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw random.trust_cpu=on systemd.mask=serial-getty@ttyS0.service systemd.mask=systemd-random-seed.service}"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS:-${DEFAULT_KERNEL_BOOT_ARGS}}"
KERNEL_BOOT_ARGS_EXTRA="${KERNEL_BOOT_ARGS_EXTRA:-}"
if [[ -n "${KERNEL_BOOT_ARGS_EXTRA}" ]]; then
  KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ${KERNEL_BOOT_ARGS_EXTRA}"
fi
K3S_BIN="${K3S_BIN:-/usr/local/bin/k3s}"
GUEST_SSH_KEY="${GUEST_SSH_KEY:-/opt/firecracker-sandbox-lab/lab_ssh_key}"
GUEST_SSH_PUB="${GUEST_SSH_PUB:-${GUEST_SSH_KEY}.pub}"
ROOTFS_SIZE_GIB="${ROOTFS_SIZE_GIB:-3}"
CONTROL_PLANE_MEM_MIB="${CONTROL_PLANE_MEM_MIB:-1536}"
AGENT_MEM_MIB="${AGENT_MEM_MIB:-1024}"
VCPU_COUNT="${VCPU_COUNT:-1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
K3S_VERSION="${K3S_VERSION:-}"
K3S_SERVER_EXTRA_ARGS="${K3S_SERVER_EXTRA_ARGS:-}"
K3S_AGENT_EXTRA_ARGS="${K3S_AGENT_EXTRA_ARGS:-}"

GATEWAY="${SUBNET_PREFIX}.1"
SERVER_IP="${SUBNET_PREFIX}.10"
CIDR="${SUBNET_PREFIX}.0/24"
TOKEN_FILE="${RUN_ROOT}/cluster-token"
ARTIFACT_PREFIX="/var/log/k2vm-k3s"

if [[ "${MODE}" != "apply" && "${MODE}" != "delete" && "${MODE}" != "status" ]]; then
  echo "usage: $0 [apply|delete|status]" >&2
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "run this script as root" >&2
  exit 2
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

validate_int() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || {
    echo "${name} must be a non-negative integer, got: ${value}" >&2
    exit 2
  }
}

validate_config() {
  validate_int SERVER_COUNT "${SERVER_COUNT}"
  validate_int AGENT_COUNT "${AGENT_COUNT}"
  validate_int ROOTFS_SIZE_GIB "${ROOTFS_SIZE_GIB}"
  validate_int CONTROL_PLANE_MEM_MIB "${CONTROL_PLANE_MEM_MIB}"
  validate_int AGENT_MEM_MIB "${AGENT_MEM_MIB}"
  validate_int VCPU_COUNT "${VCPU_COUNT}"
  (( SERVER_COUNT >= 1 )) || {
    echo "SERVER_COUNT must be at least 1" >&2
    exit 2
  }
}

node_role() {
  if (( $1 < SERVER_COUNT )); then
    echo "server"
  else
    echo "agent"
  fi
}

node_ip() {
  printf '%s.%d' "${SUBNET_PREFIX}" "$((10 + $1))"
}

node_name() {
  printf 'k3s-%02d' "$1"
}

node_tap() {
  printf '%s%d' "${TAP_PREFIX}" "$1"
}

node_mac() {
  printf '06:36:19:00:00:%02x' "$((16 + $1))"
}

node_mem() {
  if [[ "$(node_role "$1")" == "server" ]]; then
    echo "${CONTROL_PLANE_MEM_MIB}"
  else
    echo "${AGENT_MEM_MIB}"
  fi
}

SSH_OPTS=(-i "${GUEST_SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

node_ssh() {
  local idx="$1"
  shift
  ssh "${SSH_OPTS[@]}" "root@$(node_ip "${idx}")" "$@"
}

server_ssh() {
  node_ssh 0 "$@"
}

copy_guest_file() {
  local remote_path="$1"
  local local_path="$2"
  if server_ssh "test -f $(printf '%q' "${remote_path}")" >/dev/null 2>&1; then
    server_ssh "cat $(printf '%q' "${remote_path}")" >"${local_path}"
  fi
}

cleanup_run() {
  set +e
  if [[ -d "${RUN_ROOT}/nodes" ]]; then
    for pid_file in "${RUN_ROOT}"/nodes/*/pid; do
      [[ -f "${pid_file}" ]] && kill "$(cat "${pid_file}")" 2>/dev/null
    done
    sleep 1
    for pid_file in "${RUN_ROOT}"/nodes/*/pid; do
      [[ -f "${pid_file}" ]] && kill -9 "$(cat "${pid_file}")" 2>/dev/null
    done
  fi
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    ip link del "$(node_tap "${i}")" 2>/dev/null
  done
  iptables -t nat -D POSTROUTING -s "${CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE 2>/dev/null
  ip link set "${BRIDGE_NAME}" down 2>/dev/null
  ip link del "${BRIDGE_NAME}" type bridge 2>/dev/null
  rm -rf "${RUN_ROOT}"
  set -e
}

status_cluster() {
  if [[ ! -d "${RUN_ROOT}" ]]; then
    echo "no run root at ${RUN_ROOT}" >&2
    exit 1
  fi
  if ! ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" true >/dev/null 2>&1; then
    echo "cluster is not reachable at ${SERVER_IP}" >&2
    exit 1
  fi
  server_ssh "/usr/local/bin/k3s kubectl get nodes -o wide"
}

prepare_base_image() {
  local key
  local prepared
  local tmp
  local mnt
  key="$(
    {
      sha256sum "${BASE_ROOTFS}" "${KERNEL_PATH}" "${K3S_BIN}" "${GUEST_SSH_PUB}"
      printf 'packages=iptables,conntrack,ipset,ethtool,socat,ca-certificates,openssh-server\n'
      printf 'rootfs_size_gib=%s\n' "${ROOTFS_SIZE_GIB}"
    } | sha256sum | awk '{print substr($1,1,16)}'
  )"
  prepared="${CACHE_ROOT}/prepared-${key}.ext4"
  if [[ -s "${prepared}" ]]; then
    PREPARED_ROOTFS_PATH="${prepared}"
    return
  fi

  tmp="${prepared}.tmp"
  mnt="${CACHE_ROOT}/mnt-${key}"
  rm -f "${tmp}"
  cp --reflink=auto "${BASE_ROOTFS}" "${tmp}" 2>/dev/null || cp "${BASE_ROOTFS}" "${tmp}"
  set +e
  e2fsck -fy "${tmp}" >"${CACHE_ROOT}/e2fsck-${key}.log" 2>&1
  local fsck_code=$?
  set -e
  [[ "${fsck_code}" -le 1 ]] || {
    cat "${CACHE_ROOT}/e2fsck-${key}.log" >&2
    exit "${fsck_code}"
  }
  truncate -s "${ROOTFS_SIZE_GIB}G" "${tmp}"
  resize2fs "${tmp}" >"${CACHE_ROOT}/resize-${key}.log" 2>&1
  mkdir -p "${mnt}"
  mount -o loop "${tmp}" "${mnt}"
  cleanup_mounts() {
    set +e
    mountpoint -q "${mnt}/proc" && umount "${mnt}/proc"
    mountpoint -q "${mnt}/sys" && umount "${mnt}/sys"
    mountpoint -q "${mnt}/dev" && umount "${mnt}/dev"
    mountpoint -q "${mnt}/run" && umount "${mnt}/run"
    mountpoint -q "${mnt}" && umount "${mnt}"
  }
  trap cleanup_mounts RETURN

  rm -f "${mnt}/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"${mnt}/etc/resolv.conf"
  mount -t proc proc "${mnt}/proc"
  mount -t sysfs sysfs "${mnt}/sys"
  mount --bind /dev "${mnt}/dev"
  mount --bind /run "${mnt}/run"
  chroot "${mnt}" apt-get update >"${CACHE_ROOT}/apt-update-${key}.log" 2>&1
  chroot "${mnt}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iptables conntrack ipset ethtool socat ca-certificates openssh-server >"${CACHE_ROOT}/apt-install-${key}.log" 2>&1
  install -m 0755 "${K3S_BIN}" "${mnt}/usr/local/bin/k3s"
  mkdir -p "${mnt}/root/.ssh"
  cp "${GUEST_SSH_PUB}" "${mnt}/root/.ssh/authorized_keys"
  chmod 700 "${mnt}/root/.ssh"
  chmod 600 "${mnt}/root/.ssh/authorized_keys"
  if [[ -f "${mnt}/etc/ssh/sshd_config" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${mnt}/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "${mnt}/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${mnt}/etc/ssh/sshd_config" || true
  fi
  chroot "${mnt}" update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
  chroot "${mnt}" update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
  cleanup_mounts
  trap - RETURN
  mv "${tmp}" "${prepared}"
  PREPARED_ROOTFS_PATH="${prepared}"
}

write_service() {
  local role="$1"
  local name="$2"
  local ip="$3"
  local primary_url="https://${SERVER_IP}:6443"
  if [[ "${role}" == "server-bootstrap" ]]; then
    cat <<EOF
[Unit]
Description=Lightweight Kubernetes
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=K3S_TOKEN=$(cat "${TOKEN_FILE}")
ExecStart=/usr/local/bin/k3s server --cluster-init --node-name ${name} --node-ip ${ip} --advertise-address ${ip} --bind-address 0.0.0.0 --tls-san ${SERVER_IP} --tls-san ${ip} --cluster-cidr ${POD_CIDR} --service-cidr ${SERVICE_CIDR} --flannel-iface eth0 --flannel-backend=host-gw --write-kubeconfig-mode 0644 --disable traefik --disable servicelb ${K3S_SERVER_EXTRA_ARGS}
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Restart=always
RestartSec=5s
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
  elif [[ "${role}" == "server" ]]; then
    cat <<EOF
[Unit]
Description=Lightweight Kubernetes
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=K3S_TOKEN=$(cat "${TOKEN_FILE}")
ExecStart=/usr/local/bin/k3s server --server ${primary_url} --node-name ${name} --node-ip ${ip} --advertise-address ${ip} --bind-address 0.0.0.0 --tls-san ${SERVER_IP} --tls-san ${ip} --cluster-cidr ${POD_CIDR} --service-cidr ${SERVICE_CIDR} --flannel-iface eth0 --flannel-backend=host-gw --write-kubeconfig-mode 0644 --disable traefik --disable servicelb ${K3S_SERVER_EXTRA_ARGS}
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Restart=always
RestartSec=5s
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
  else
    cat <<EOF
[Unit]
Description=Lightweight Kubernetes Agent
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Environment=K3S_TOKEN=$(cat "${TOKEN_FILE}")
ExecStart=/usr/local/bin/k3s agent --server ${primary_url} --node-name ${name} --node-ip ${ip} --flannel-iface eth0 ${K3S_AGENT_EXTRA_ARGS}
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Restart=always
RestartSec=5s
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
  fi
}

configure_node() {
  local idx="$1"
  local vm_dir="$2"
  local ip
  local name
  local mnt
  local role
  ip="$(node_ip "${idx}")"
  name="$(node_name "${idx}")"
  role="$(node_role "${idx}")"

  cp --reflink=auto "${PREPARED_ROOTFS_PATH}" "${vm_dir}/rootfs.ext4" 2>/dev/null || cp "${PREPARED_ROOTFS_PATH}" "${vm_dir}/rootfs.ext4"
  e2fsck -fy "${vm_dir}/rootfs.ext4" >/dev/null 2>&1 || true
  mnt="${vm_dir}/mnt"
  mkdir -p "${mnt}"
  mount -o loop "${vm_dir}/rootfs.ext4" "${mnt}"
  cleanup_vm_mount() {
    set +e
    mountpoint -q "${mnt}" && umount "${mnt}"
  }
  trap cleanup_vm_mount RETURN

  printf '%s\n' "${name}" >"${mnt}/etc/hostname"
  cat >"${mnt}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${name}
${ip} ${name}
EOF
  cat >"${mnt}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${ip}
    netmask 255.255.255.0
    gateway ${GATEWAY}
EOF
  rm -f "${mnt}/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"${mnt}/etc/resolv.conf"
  rm -f "${mnt}/etc/machine-id" "${mnt}/var/lib/dbus/machine-id" 2>/dev/null || true
  touch "${mnt}/etc/machine-id"
  rm -rf "${mnt}/var/lib/rancher/k3s" "${mnt}/var/lib/kubelet" "${mnt}/run/k3s" "${mnt}/run/flannel" 2>/dev/null || true
  mkdir -p "${mnt}/etc/systemd/system/multi-user.target.wants"
  if (( idx == 0 )); then
    write_service "server-bootstrap" "${name}" "${ip}" >"${mnt}/etc/systemd/system/k3s.service"
  elif [[ "${role}" == "server" ]]; then
    write_service "server" "${name}" "${ip}" >"${mnt}/etc/systemd/system/k3s.service"
  else
    write_service "agent" "${name}" "${ip}" >"${mnt}/etc/systemd/system/k3s.service"
  fi
  ln -sf /etc/systemd/system/k3s.service "${mnt}/etc/systemd/system/multi-user.target.wants/k3s.service"
  ln -sf /lib/systemd/system/ssh.service "${mnt}/etc/systemd/system/multi-user.target.wants/ssh.service"
  cleanup_vm_mount
  trap - RETURN
}

boot_node() {
  local idx="$1"
  local vm_dir="${RUN_ROOT}/nodes/node${idx}"
  local tap
  local mac
  local mem
  mkdir -p "${vm_dir}"
  configure_node "${idx}" "${vm_dir}"
  tap="$(node_tap "${idx}")"
  mac="$(node_mac "${idx}")"
  mem="$(node_mem "${idx}")"
  ip tuntap add dev "${tap}" mode tap 2>/dev/null || true
  ip link set "${tap}" master "${BRIDGE_NAME}"
  ip link set "${tap}" up
  cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF
  "${FIRECRACKER_BIN}" --api-sock "${vm_dir}/fc.sock" --config-file "${vm_dir}/vm.json" >"${vm_dir}/console.log" 2>&1 &
  echo $! >"${vm_dir}/pid"
}

setup_bridge() {
  ip link add name "${BRIDGE_NAME}" type bridge 2>/dev/null || true
  ip addr add "${GATEWAY}/24" dev "${BRIDGE_NAME}" 2>/dev/null || true
  ip link set "${BRIDGE_NAME}" up
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! iptables -C FORWARD -i "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${BRIDGE_NAME}" -j ACCEPT
  fi
  if ! iptables -C FORWARD -o "${BRIDGE_NAME}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -o "${BRIDGE_NAME}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  fi
  if ! iptables -t nat -C POSTROUTING -s "${CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE
  fi
}

wait_for_ssh() {
  local ip="$1"
  for _ in $(seq 1 120); do
    if ssh "${SSH_OPTS[@]}" "root@${ip}" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_cluster() {
  local ready_count="0"
  for _ in $(seq 1 360); do
    nodes_text="$(server_ssh "/usr/local/bin/k3s kubectl get nodes -o wide --no-headers 2>/dev/null" || true)"
    printf '%s\n' "${nodes_text}" >"${RUN_ROOT}/nodes.txt"
    ready_count="$(printf '%s\n' "${nodes_text}" | awk '$2=="Ready"{c++} END{print c+0}')"
    if [[ "${ready_count}" -ge "${NODE_COUNT}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

run_smoke() {
  server_ssh "cat >/root/run-smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
kubectl create namespace smoke --dry-run=client -o yaml | kubectl apply -f -
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-smoke
  namespace: smoke
spec:
  selector:
    matchLabels:
      app: node-smoke
  template:
    metadata:
      labels:
        app: node-smoke
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: node-smoke
          image: busybox:1.36
          command: ["sh", "-lc", "sleep 3600"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: smoke
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: echo
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: smoke
spec:
  selector:
    app: echo
  ports:
    - port: 80
      targetPort: 80
YAML
kubectl -n smoke rollout status daemonset/node-smoke --timeout=240s
kubectl -n smoke rollout status deployment/echo --timeout=240s
kubectl -n kube-system rollout status deployment/coredns --timeout=240s
cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: dns-http
  namespace: smoke
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: dns-http
          image: busybox:1.36
          command:
            - sh
            - -lc
            - |
              for _ in $(seq 1 30); do
                nslookup echo.smoke.svc.cluster.local && \
                wget -qO- http://echo.smoke.svc.cluster.local >/tmp/echo.html && \
                test -s /tmp/echo.html && exit 0
                sleep 2
              done
              exit 1
YAML
kubectl -n smoke wait --for=condition=complete job/dns-http --timeout=240s
kubectl get nodes -o wide > /var/log/k2vm-k3s.nodes 2>&1
kubectl get pods -A -o wide > /var/log/k2vm-k3s.pods 2>&1
kubectl -n smoke get pods -o wide > /var/log/k2vm-k3s.smoke-pods 2>&1
kubectl -n smoke logs job/dns-http > /var/log/k2vm-k3s.smoke-job.log 2>&1
EOF
  server_ssh "chmod +x /root/run-smoke.sh && /root/run-smoke.sh"
}

collect_artifacts() {
  mkdir -p "${RUN_ROOT}/artifacts"
  copy_guest_file "${ARTIFACT_PREFIX}.nodes" "${RUN_ROOT}/artifacts/nodes.txt"
  copy_guest_file "${ARTIFACT_PREFIX}.pods" "${RUN_ROOT}/artifacts/pods.txt"
  copy_guest_file "${ARTIFACT_PREFIX}.smoke-pods" "${RUN_ROOT}/artifacts/smoke-pods.txt"
  copy_guest_file "${ARTIFACT_PREFIX}.smoke-job.log" "${RUN_ROOT}/artifacts/smoke-job.log"
  server_ssh "cat /etc/rancher/k3s/k3s.yaml" | sed "s#https://127.0.0.1:6443#https://${SERVER_IP}:6443#g; s#https://0.0.0.0:6443#https://${SERVER_IP}:6443#g" >"${RUN_ROOT}/artifacts/kubeconfig.yaml"
  cat >"${RUN_ROOT}/artifacts/receipt.json" <<EOF
{"cluster":"k2vm-k3s","status":"succeeded","serverCount":${SERVER_COUNT},"agentCount":${AGENT_COUNT},"nodeCount":${NODE_COUNT},"serverIP":"${SERVER_IP}","cidr":"${CIDR}","podCIDR":"${POD_CIDR}","serviceCIDR":"${SERVICE_CIDR}","k3sVersion":"${K3S_VERSION}"}
EOF
}

apply_cluster() {
  validate_config
  for cmd in cp curl e2fsck ip iptables mount openssl resize2fs sha256sum ssh sysctl truncate umount; do
    require_cmd "${cmd}"
  done
  for path in "${BASE_ROOTFS}" "${KERNEL_PATH}" "${K3S_BIN}" "${FIRECRACKER_BIN}" "${GUEST_SSH_KEY}" "${GUEST_SSH_PUB}"; do
    [[ -e "${path}" ]] || {
      echo "missing required path: ${path}" >&2
      exit 2
    }
  done

  mkdir -p "${RUN_ROOT}" "${CACHE_ROOT}"
  cleanup_run || true
  prepare_base_image
  openssl rand -hex 24 >"${TOKEN_FILE}"
  chmod 0600 "${TOKEN_FILE}"
  setup_bridge
  mkdir -p "${RUN_ROOT}/nodes"
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    boot_node "${i}"
  done
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    wait_for_ssh "$(node_ip "${i}")"
  done
  wait_for_cluster
  run_smoke
  collect_artifacts
  server_ssh "/usr/local/bin/k3s kubectl get nodes -o wide"
}

case "${MODE}" in
  apply)
    apply_cluster
    ;;
  delete)
    cleanup_run
    ;;
  status)
    status_cluster
    ;;
esac
