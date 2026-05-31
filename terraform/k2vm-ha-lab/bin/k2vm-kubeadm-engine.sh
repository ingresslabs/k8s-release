#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-apply}"

RUN_ROOT="${RUN_ROOT:-/var/lib/kubeadm-firecracker-ha}"
CACHE_ROOT="${CACHE_ROOT:-/var/cache/kubeadm-firecracker-ha}"
CONTROL_PLANE_COUNT="${CONTROL_PLANE_COUNT:-3}"
WORKER_COUNT="${WORKER_COUNT:-0}"
NODE_COUNT="$((CONTROL_PLANE_COUNT + WORKER_COUNT))"

SUBNET_PREFIX="${SUBNET_PREFIX:-198.19.0}"
BRIDGE_NAME="${BRIDGE_NAME:-k8sha198}"
TAP_PREFIX="${TAP_PREFIX:-k8sha198}"
FIRECRACKER_BIN="${FIRECRACKER_BIN:-/usr/local/bin/firecracker}"
FIRECRACKER_ARCH="${FIRECRACKER_ARCH:-$(uname -m)}"
FIRECRACKER_CI_VERSION="${FIRECRACKER_CI_VERSION:-}"
KERNEL_PATH="${KERNEL_PATH:-}"
KERNEL_MODULES_TAR_PATH="${KERNEL_MODULES_TAR_PATH:-}"
LINUXKIT_KERNEL_IMAGE="${LINUXKIT_KERNEL_IMAGE:-linuxkit/kernel:6.12.59}"
INITRD_PATH="${INITRD_PATH:-}"
DEFAULT_KERNEL_BOOT_ARGS="${DEFAULT_KERNEL_BOOT_ARGS:-console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw random.trust_cpu=on systemd.mask=serial-getty@ttyS0.service systemd.mask=systemd-random-seed.service}"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS:-${DEFAULT_KERNEL_BOOT_ARGS}}"
KERNEL_BOOT_ARGS_EXTRA="${KERNEL_BOOT_ARGS_EXTRA:-}"
if [[ -n "${KERNEL_BOOT_ARGS_EXTRA}" ]]; then
  KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ${KERNEL_BOOT_ARGS_EXTRA}"
fi
BASE_ROOTFS_PATH="${BASE_ROOTFS_PATH:-}"
ROOTFS_SQUASHFS_PATH="${ROOTFS_SQUASHFS_PATH:-}"
ROOTFS_SIZE_GIB="${ROOTFS_SIZE_GIB:-12}"

GUEST_SSH_KEY="${GUEST_SSH_KEY:-${CACHE_ROOT}/lab_ssh_key}"
GUEST_SSH_PUB="${GUEST_SSH_KEY}.pub"
SSH_OPTS=(-i "${GUEST_SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.36}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
PACKAGE_REPO_ROOT="${PACKAGE_REPO_ROOT:-}"
PACKAGE_REPO_MODE="${PACKAGE_REPO_MODE:-hybrid}"
PACKAGE_REPO_LAYOUT="${PACKAGE_REPO_LAYOUT:-prebuilt_repo}"
PACKAGE_REPO_TRUSTED="${PACKAGE_REPO_TRUSTED:-0}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.3.0}"
NETWORK_PLUGIN="${NETWORK_PLUGIN:-flannel}"
CONTROL_PLANE_RUNTIME="${CONTROL_PLANE_RUNTIME:-static-pods}"
GUEST_SELINUX_MODE="${GUEST_SELINUX_MODE:-enforcing}"
NSJAIL_VERSION="${NSJAIL_VERSION:-3.6}"
CILIUM_VERSION="${CILIUM_VERSION:-v1.19.4}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-}"
CILIUM_CONNECTIVITY_TEST="${CILIUM_CONNECTIVITY_TEST:-0}"
INSTALL_ISTIO="${INSTALL_ISTIO:-0}"
ISTIOCTL_BIN="${ISTIOCTL_BIN:-}"
ISTIO_PROFILE="${ISTIO_PROFILE:-minimal}"
ISTIO_VERSION="${ISTIO_VERSION:-}"
FLANNEL_VERSION="${FLANNEL_VERSION:-}"
if [[ -n "${FLANNEL_MANIFEST_URL:-}" ]]; then
  FLANNEL_MANIFEST_URL="${FLANNEL_MANIFEST_URL}"
elif [[ -n "${FLANNEL_VERSION}" ]]; then
  FLANNEL_MANIFEST_URL="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
else
  FLANNEL_MANIFEST_URL="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
fi

HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.2.19-alpine}"
API_LB_IP="${API_LB_IP:-${SUBNET_PREFIX}.5}"
API_LB_PORT="${API_LB_PORT:-6443}"
API_LB_ENDPOINT="${API_LB_IP}:${API_LB_PORT}"
API_LB_CONTAINER_NAME="${API_LB_CONTAINER_NAME:-kubeadm-ha-api-lb-${BRIDGE_NAME}}"

CONTROL_PLANE_MEM_MIB="${CONTROL_PLANE_MEM_MIB:-2048}"
WORKER_MEM_MIB="${WORKER_MEM_MIB:-1536}"
VCPU_COUNT="${VCPU_COUNT:-2}"

GATEWAY="${SUBNET_PREFIX}.1"
PRIMARY_CONTROL_PLANE_IP="${SUBNET_PREFIX}.10"
CIDR="${SUBNET_PREFIX}.0/24"
ARTIFACT_PREFIX="/var/log/kubeadm-ha-lab"
ARTIFACT_DIR="${RUN_ROOT}/artifacts"
HOST_TOOLS_DIR="${RUN_ROOT}/host-tools"
HOST_KUBECTL_ROOT="${HOST_TOOLS_DIR}/kubectl-root"
HOST_KUBECTL_BIN="${HOST_TOOLS_DIR}/kubectl"
HOST_KUBECONFIG_PATH="${HOST_TOOLS_DIR}/kubeconfig.yaml"
APPLY_ACTIVE="0"

if [[ "${MODE}" != "apply" && "${MODE}" != "delete" && "${MODE}" != "status" ]]; then
  echo "usage: $0 [apply|delete|status]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run this script on the Linux lab host" >&2
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
  validate_int CONTROL_PLANE_COUNT "${CONTROL_PLANE_COUNT}"
  validate_int WORKER_COUNT "${WORKER_COUNT}"
  validate_int NODE_COUNT "${NODE_COUNT}"
  validate_int ROOTFS_SIZE_GIB "${ROOTFS_SIZE_GIB}"
  validate_int CONTROL_PLANE_MEM_MIB "${CONTROL_PLANE_MEM_MIB}"
  validate_int WORKER_MEM_MIB "${WORKER_MEM_MIB}"
  validate_int VCPU_COUNT "${VCPU_COUNT}"

  if (( CONTROL_PLANE_COUNT != 3 )); then
    echo "CONTROL_PLANE_COUNT must be 3 for this stacked-etcd lab" >&2
    exit 2
  fi
  if (( WORKER_COUNT < 0 )); then
    echo "WORKER_COUNT must be zero or greater" >&2
    exit 2
  fi
  if (( NODE_COUNT < CONTROL_PLANE_COUNT )); then
    echo "NODE_COUNT must be at least CONTROL_PLANE_COUNT" >&2
    exit 2
  fi
  case "${NETWORK_PLUGIN}" in
    cilium|flannel)
      ;;
    *)
      echo "NETWORK_PLUGIN must be either cilium or flannel" >&2
      exit 2
      ;;
  esac
  case "${CILIUM_CONNECTIVITY_TEST}" in
    0|1)
      ;;
    *)
      echo "CILIUM_CONNECTIVITY_TEST must be 0 or 1" >&2
      exit 2
      ;;
  esac
  case "${INSTALL_ISTIO}" in
    0|1)
      ;;
    *)
      echo "INSTALL_ISTIO must be 0 or 1" >&2
      exit 2
      ;;
  esac
  case "${CONTROL_PLANE_RUNTIME}" in
    static-pods|nsjail)
      ;;
    *)
      echo "CONTROL_PLANE_RUNTIME must be static-pods or nsjail" >&2
      exit 2
      ;;
  esac
  case "${GUEST_SELINUX_MODE}" in
    disabled|permissive|enforcing)
      ;;
    *)
      echo "GUEST_SELINUX_MODE must be disabled, permissive, or enforcing" >&2
      exit 2
      ;;
  esac
  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" && -z "${PACKAGE_REPO_ROOT}" ]]; then
    echo "CONTROL_PLANE_RUNTIME=nsjail requires PACKAGE_REPO_ROOT with k8s-release control-plane packages" >&2
    exit 2
  fi
  if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
    [[ -d "${PACKAGE_REPO_ROOT}/debian" ]] || {
      echo "PACKAGE_REPO_ROOT must contain debian/: ${PACKAGE_REPO_ROOT}" >&2
      exit 2
    }
    case "${PACKAGE_REPO_LAYOUT}" in
      prebuilt_repo|component_packages)
        ;;
      *)
        echo "PACKAGE_REPO_LAYOUT must be prebuilt_repo or component_packages" >&2
        exit 2
        ;;
    esac
    case "${PACKAGE_REPO_TRUSTED}" in
      0|1)
        ;;
      *)
        echo "PACKAGE_REPO_TRUSTED must be 0 or 1" >&2
        exit 2
        ;;
    esac
    if [[ "${PACKAGE_REPO_LAYOUT}" == "component_packages" ]]; then
      if [[ ! -f "${PACKAGE_REPO_ROOT}/debian/Packages" && ! -f "${PACKAGE_REPO_ROOT}/debian/Packages.gz" ]]; then
        echo "component_packages repository must contain debian/Packages or debian/Packages.gz: ${PACKAGE_REPO_ROOT}" >&2
        exit 2
      fi
    elif [[ "${PACKAGE_REPO_TRUSTED}" != "1" && ! -f "${PACKAGE_REPO_ROOT}/repo-signing-key.asc" ]]; then
      echo "prebuilt_repo repository must contain repo-signing-key.asc unless PACKAGE_REPO_TRUSTED=1: ${PACKAGE_REPO_ROOT}" >&2
      exit 2
    fi
    case "${PACKAGE_REPO_MODE}" in
      hybrid|strict)
        ;;
      *)
        echo "PACKAGE_REPO_MODE must be hybrid or strict" >&2
        exit 2
        ;;
    esac
  fi
}

node_role() {
  if (( $1 < CONTROL_PLANE_COUNT )); then
    echo "control-plane"
  else
    echo "worker"
  fi
}

node_ip() {
  printf '%s.%d' "${SUBNET_PREFIX}" "$((10 + $1))"
}

node_name() {
  printf 'k8s-%02d' "$1"
}

node_tap() {
  printf '%s%d' "${TAP_PREFIX}" "$1"
}

node_mac() {
  local idx="$1"
  printf '06:36:00:00:00:%02x' "$((16 + idx))"
}

node_mem() {
  if [[ "$(node_role "$1")" == "control-plane" ]]; then
    echo "${CONTROL_PLANE_MEM_MIB}"
  else
    echo "${WORKER_MEM_MIB}"
  fi
}

cni_arch() {
  case "${FIRECRACKER_ARCH}" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)
      echo "unsupported CNI architecture: ${FIRECRACKER_ARCH}" >&2
      exit 2
      ;;
  esac
}

ensure_guest_ssh_key() {
  if [[ -f "${GUEST_SSH_KEY}" && -f "${GUEST_SSH_PUB}" ]]; then
    return
  fi
  mkdir -p "$(dirname "${GUEST_SSH_KEY}")"
  rm -f "${GUEST_SSH_KEY}" "${GUEST_SSH_PUB}"
  ssh-keygen -q -t ed25519 -N "" -f "${GUEST_SSH_KEY}" >/dev/null
}

detect_firecracker_ci_version() {
  local version
  version="$("${FIRECRACKER_BIN}" --version 2>/dev/null | awk '{print $2}')"
  [[ -n "${version}" ]] || {
    echo "unable to determine Firecracker version from ${FIRECRACKER_BIN}" >&2
    exit 2
  }
  printf '%s\n' "${version%.*}"
}

download_firecracker_assets() {
  local ci_version
  local ubuntu_key
  local linuxkit_key
  local linuxkit_cache_dir
  local linuxkit_kernel_path
  local linuxkit_bzimage_path
  local linuxkit_modules_path
  local linuxkit_dev_tar_path
  local linuxkit_headers_dir
  local linuxkit_cid=""
  local download_dir="${CACHE_ROOT}/downloads"

  if [[ -n "${KERNEL_PATH}" ]]; then
    [[ -f "${KERNEL_PATH}" ]] || {
      echo "missing kernel path: ${KERNEL_PATH}" >&2
      exit 2
    }
  fi
  if [[ -n "${KERNEL_MODULES_TAR_PATH}" ]]; then
    [[ -f "${KERNEL_MODULES_TAR_PATH}" ]] || {
      echo "missing kernel modules tar path: ${KERNEL_MODULES_TAR_PATH}" >&2
      exit 2
    }
  fi
  if [[ -n "${BASE_ROOTFS_PATH}" ]]; then
    [[ -f "${BASE_ROOTFS_PATH}" ]] || {
      echo "missing base rootfs path: ${BASE_ROOTFS_PATH}" >&2
      exit 2
    }
  fi
  if [[ -n "${ROOTFS_SQUASHFS_PATH}" ]]; then
    [[ -f "${ROOTFS_SQUASHFS_PATH}" ]] || {
      echo "missing rootfs squashfs path: ${ROOTFS_SQUASHFS_PATH}" >&2
      exit 2
    }
  fi
  if [[ -n "${KERNEL_PATH}" && ( -n "${BASE_ROOTFS_PATH}" || -n "${ROOTFS_SQUASHFS_PATH}" ) ]]; then
    return
  fi

  mkdir -p "${download_dir}"

  if [[ -z "${KERNEL_PATH}" ]]; then
    linuxkit_key="$(printf '%s\n' "${LINUXKIT_KERNEL_IMAGE}" | sha256sum | awk '{print substr($1,1,16)}')"
    linuxkit_cache_dir="${download_dir}/linuxkit-${linuxkit_key}"
    linuxkit_kernel_path="${linuxkit_cache_dir}/vmlinux"
    linuxkit_bzimage_path="${linuxkit_cache_dir}/kernel"
    linuxkit_modules_path="${linuxkit_cache_dir}/kernel.tar"
    linuxkit_dev_tar_path="${linuxkit_cache_dir}/kernel-dev.tar"
    mkdir -p "${linuxkit_cache_dir}"
    if [[ ! -f "${linuxkit_kernel_path}" || ! -f "${linuxkit_modules_path}" ]]; then
      rm -rf "${linuxkit_cache_dir}.tmp"
      mkdir -p "${linuxkit_cache_dir}.tmp"
      docker pull "${LINUXKIT_KERNEL_IMAGE}" >/dev/null
      linuxkit_cid="$(docker create "${LINUXKIT_KERNEL_IMAGE}" /bin/sh)"
      trap '[[ -n "${linuxkit_cid}" ]] && docker rm -f "${linuxkit_cid}" >/dev/null 2>&1 || true; rm -rf "${linuxkit_cache_dir}.tmp"' RETURN
      docker cp "${linuxkit_cid}:/kernel" "${linuxkit_cache_dir}.tmp/kernel"
      docker cp "${linuxkit_cid}:/kernel.tar" "${linuxkit_cache_dir}.tmp/kernel.tar"
      docker cp "${linuxkit_cid}:/kernel-dev.tar" "${linuxkit_cache_dir}.tmp/kernel-dev.tar"
      linuxkit_headers_dir="$(
        tar -tf "${linuxkit_cache_dir}.tmp/kernel-dev.tar" |
          sed -n 's#^\(usr/src/linux-headers-[^/]*\)/scripts/extract-vmlinux$#\1#p' |
          head -n 1
      )"
      [[ -n "${linuxkit_headers_dir}" ]] || {
        echo "failed to locate LinuxKit extract-vmlinux helper" >&2
        exit 1
      }
      tar -xOf "${linuxkit_cache_dir}.tmp/kernel-dev.tar" "${linuxkit_headers_dir}/scripts/extract-vmlinux" >"${linuxkit_cache_dir}.tmp/extract-vmlinux"
      chmod +x "${linuxkit_cache_dir}.tmp/extract-vmlinux"
      "${linuxkit_cache_dir}.tmp/extract-vmlinux" "${linuxkit_cache_dir}.tmp/kernel" >"${linuxkit_cache_dir}.tmp/vmlinux"
      docker rm -f "${linuxkit_cid}" >/dev/null 2>&1 || true
      linuxkit_cid=""
      mv "${linuxkit_cache_dir}.tmp/kernel" "${linuxkit_bzimage_path}"
      mv "${linuxkit_cache_dir}.tmp/vmlinux" "${linuxkit_kernel_path}"
      mv "${linuxkit_cache_dir}.tmp/kernel.tar" "${linuxkit_modules_path}"
      mv "${linuxkit_cache_dir}.tmp/kernel-dev.tar" "${linuxkit_dev_tar_path}"
      rm -rf "${linuxkit_cache_dir}.tmp"
      trap - RETURN
    fi
    KERNEL_PATH="${linuxkit_kernel_path}"
    if [[ -z "${KERNEL_MODULES_TAR_PATH}" ]]; then
      KERNEL_MODULES_TAR_PATH="${linuxkit_modules_path}"
    fi
  fi

  if [[ -z "${BASE_ROOTFS_PATH}" && -z "${ROOTFS_SQUASHFS_PATH}" ]]; then
    ci_version="${FIRECRACKER_CI_VERSION:-$(detect_firecracker_ci_version)}"
    ubuntu_key="$(
      curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min?prefix=firecracker-ci/${ci_version}/${FIRECRACKER_ARCH}/ubuntu-&list-type=2" |
        grep -oP "(?<=<Key>)(firecracker-ci/${ci_version}/${FIRECRACKER_ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" |
        sort -V | tail -1
    )"
    [[ -n "${ubuntu_key}" ]] || {
      echo "unable to resolve Firecracker Ubuntu rootfs asset for ${ci_version}/${FIRECRACKER_ARCH}" >&2
      exit 2
    }
    ROOTFS_SQUASHFS_PATH="${download_dir}/$(basename "${ubuntu_key}")"
    if [[ ! -f "${ROOTFS_SQUASHFS_PATH}" ]]; then
      curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/${ubuntu_key}" -o "${ROOTFS_SQUASHFS_PATH}"
    fi
  fi
}

ensure_base_rootfs() {
  if [[ -n "${BASE_ROOTFS_PATH}" ]]; then
    [[ -f "${BASE_ROOTFS_PATH}" ]] || {
      echo "missing base rootfs path: ${BASE_ROOTFS_PATH}" >&2
      exit 2
    }
    return
  fi

  local base_key
  local base_dir="${CACHE_ROOT}/base"
  local tmp_dir
  local tmp_img
  mkdir -p "${base_dir}"
  base_key="$(
    {
      sha256sum "${ROOTFS_SQUASHFS_PATH}"
      sha256sum "${GUEST_SSH_PUB}"
    } | sha256sum | awk '{print substr($1,1,16)}'
  )"
  BASE_ROOTFS_PATH="${base_dir}/ubuntu-${base_key}.ext4"
  if [[ -s "${BASE_ROOTFS_PATH}" ]]; then
    return
  fi

  tmp_dir="${base_dir}/ubuntu-${base_key}.rootfs"
  tmp_img="${BASE_ROOTFS_PATH}.tmp"
  rm -rf "${tmp_dir}"
  rm -f "${tmp_img}"
  mkdir -p "${tmp_dir}"

  unsquashfs -d "${tmp_dir}/rootfs" "${ROOTFS_SQUASHFS_PATH}" >/dev/null
  mkdir -p "${tmp_dir}/rootfs/root/.ssh"
  chmod 700 "${tmp_dir}/rootfs/root/.ssh"
  cp "${GUEST_SSH_PUB}" "${tmp_dir}/rootfs/root/.ssh/authorized_keys"
  chmod 600 "${tmp_dir}/rootfs/root/.ssh/authorized_keys"
  if [[ -f "${tmp_dir}/rootfs/etc/ssh/sshd_config" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${tmp_dir}/rootfs/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "${tmp_dir}/rootfs/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${tmp_dir}/rootfs/etc/ssh/sshd_config" || true
  fi
  chown -R root:root "${tmp_dir}/rootfs"

  truncate -s 4G "${tmp_img}"
  mkfs.ext4 -d "${tmp_dir}/rootfs" -F "${tmp_img}" >/dev/null
  mv "${tmp_img}" "${BASE_ROOTFS_PATH}"
  rm -rf "${tmp_dir}"
}

prepare_base_image() {
  local key
  local prepared
  local tmp
  local mnt
  local cni_arch_value
  local pause_image
  local prepare_failed="0"

  cni_arch_value="$(cni_arch)"
  key="$(
    {
      sha256sum "${BASE_ROOTFS_PATH}" "${KERNEL_PATH}" "${GUEST_SSH_PUB}"
      if [[ -n "${KERNEL_MODULES_TAR_PATH}" ]]; then
        sha256sum "${KERNEL_MODULES_TAR_PATH}"
      fi
      if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
        [[ -f "${PACKAGE_REPO_ROOT}/repo-signing-key.asc" ]] && sha256sum "${PACKAGE_REPO_ROOT}/repo-signing-key.asc"
        [[ -f "${PACKAGE_REPO_ROOT}/SHA256SUMS" ]] && sha256sum "${PACKAGE_REPO_ROOT}/SHA256SUMS"
        [[ -f "${PACKAGE_REPO_ROOT}/debian/Packages" ]] && sha256sum "${PACKAGE_REPO_ROOT}/debian/Packages"
        [[ -f "${PACKAGE_REPO_ROOT}/debian/Packages.gz" ]] && sha256sum "${PACKAGE_REPO_ROOT}/debian/Packages.gz"
        printf 'package_repo_mode=%s\n' "${PACKAGE_REPO_MODE}"
        printf 'package_repo_layout=%s\n' "${PACKAGE_REPO_LAYOUT}"
        printf 'package_repo_trusted=%s\n' "${PACKAGE_REPO_TRUSTED}"
      fi
      printf 'kubernetes_minor=%s\n' "${KUBERNETES_MINOR}"
      printf 'kubernetes_version=%s\n' "${KUBERNETES_VERSION}"
      printf 'cni_plugins=%s\n' "${CNI_PLUGINS_VERSION}"
      printf 'flannel_manifest_url=%s\n' "${FLANNEL_MANIFEST_URL}"
      printf 'rootfs_size_gib=%s\n' "${ROOTFS_SIZE_GIB}"
      printf 'control_plane_runtime=%s\n' "${CONTROL_PLANE_RUNTIME}"
      printf 'guest_selinux_mode=%s\n' "${GUEST_SELINUX_MODE}"
      printf 'nsjail_version=%s\n' "${NSJAIL_VERSION}"
      printf 'generation=kubeadm-firecracker-ha-v9\n'
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
  cp --reflink=auto "${BASE_ROOTFS_PATH}" "${tmp}" 2>/dev/null || cp "${BASE_ROOTFS_PATH}" "${tmp}"
  set +e
  e2fsck -fy "${tmp}" >"${CACHE_ROOT}/e2fsck-${key}.log" 2>&1
  local fsck_code=$?
  set -e
  [[ "${fsck_code}" -le 1 ]] || {
    cat "${CACHE_ROOT}/e2fsck-${key}.log" >&2
    return "${fsck_code}"
  }
  truncate -s "${ROOTFS_SIZE_GIB}G" "${tmp}"
  resize2fs "${tmp}" >"${CACHE_ROOT}/resize-${key}.log" 2>&1

  mkdir -p "${mnt}"
  mount -o loop "${tmp}" "${mnt}"
  cleanup_mounts() {
    set +e
    if mountpoint -q "${mnt}/dev/pts"; then
      umount "${mnt}/dev/pts" 2>/dev/null || umount -l "${mnt}/dev/pts" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}/proc"; then
      umount "${mnt}/proc" 2>/dev/null || umount -l "${mnt}/proc" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}/sys"; then
      umount "${mnt}/sys" 2>/dev/null || umount -l "${mnt}/sys" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}/dev"; then
      umount "${mnt}/dev" 2>/dev/null || umount -l "${mnt}/dev" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}/run"; then
      umount "${mnt}/run" 2>/dev/null || umount -l "${mnt}/run" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}/opt/k8s-release-repo"; then
      umount "${mnt}/opt/k8s-release-repo" 2>/dev/null || umount -l "${mnt}/opt/k8s-release-repo" 2>/dev/null || true
    fi
    if mountpoint -q "${mnt}"; then
      umount "${mnt}" 2>/dev/null || umount -l "${mnt}" 2>/dev/null || true
    fi
    if [[ "${prepare_failed}" == "1" ]]; then
      rm -f "${tmp}"
    fi
  }
  fail_prepare() {
    prepare_failed="1"
    cleanup_mounts
    rm -f "${tmp}"
  }
  cleanup_mounts_return() {
    local status="$?"
    cleanup_mounts
    return "${status}"
  }
  trap cleanup_mounts_return RETURN
  trap fail_prepare ERR

  rm -f "${mnt}/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' >"${mnt}/etc/resolv.conf"
  if [[ -n "${KERNEL_MODULES_TAR_PATH}" ]]; then
    rm -rf "${mnt}/lib/modules"
    mkdir -p "${mnt}/lib"
    if ! tar -xf "${KERNEL_MODULES_TAR_PATH}" -C "${mnt}" ./lib/modules; then
      echo "failed to install kernel modules into guest rootfs" >&2
      prepare_failed="1"
      return 1
    fi
  fi
  chmod 1777 "${mnt}/tmp"
  mkdir -p "${mnt}/dev/pts" "${mnt}/var/cache/apt/archives/partial" "${mnt}/var/lib/apt/lists/partial" "${mnt}/var/log/apt"
  touch "${mnt}/var/log/dpkg.log"
  mkdir -p "${mnt}/root/.ssh"
  chmod 700 "${mnt}/root/.ssh"
  cp "${GUEST_SSH_PUB}" "${mnt}/root/.ssh/authorized_keys"
  chmod 600 "${mnt}/root/.ssh/authorized_keys"
  chown -R root:root "${mnt}/root/.ssh"
  if [[ -f "${mnt}/etc/ssh/sshd_config" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${mnt}/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "${mnt}/etc/ssh/sshd_config" || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${mnt}/etc/ssh/sshd_config" || true
  fi
  mount -t proc proc "${mnt}/proc"
  mount -t sysfs sysfs "${mnt}/sys"
  mount --bind /dev "${mnt}/dev"
  mount -t devpts devpts "${mnt}/dev/pts"
  mount --bind /run "${mnt}/run"

  if ! chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update >"${CACHE_ROOT}/apt-update-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-update-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi
  if ! DEBIAN_FRONTEND=noninteractive chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends \
    apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg iptables ipset jq openssh-server python3 python3-yaml socat tar xz-utils >"${CACHE_ROOT}/apt-install-base-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-install-base-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi

  mkdir -p "${mnt}/etc/apt/keyrings"
  mkdir -p "${mnt}/etc/apt/sources.list.d"
  if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
    mkdir -p "${mnt}/opt/k8s-release-repo"
    mount --bind "${PACKAGE_REPO_ROOT}" "${mnt}/opt/k8s-release-repo"
  fi
  local docker_arch
  local docker_codename
  docker_arch="$(chroot "${mnt}" /usr/bin/dpkg --print-architecture)"
  docker_codename="$(awk -F= '/^VERSION_CODENAME=/{print $2}' "${mnt}/etc/os-release")"
  if ! chroot "${mnt}" /usr/bin/curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" |
    chroot "${mnt}" /usr/bin/gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
    echo "failed to install Docker apt keyring inside guest rootfs" >&2
    prepare_failed="1"
    return 1
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "${docker_arch}" "${docker_codename}" >"${mnt}/etc/apt/sources.list.d/docker.list"
  if ! chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update >"${CACHE_ROOT}/apt-update-docker-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-update-docker-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi
  if ! DEBIAN_FRONTEND=noninteractive chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y containerd.io >"${CACHE_ROOT}/apt-install-containerd-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-install-containerd-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi

  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
    local nsjail_src_dir="/usr/local/src/nsjail-${NSJAIL_VERSION}"
    if ! DEBIAN_FRONTEND=noninteractive chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends \
      autoconf bison flex g++ gcc git libnl-route-3-dev libprotobuf-dev libtool make pkg-config protobuf-compiler >"${CACHE_ROOT}/apt-install-nsjail-builddeps-${key}.log" 2>&1; then
      cat "${CACHE_ROOT}/apt-install-nsjail-builddeps-${key}.log" >&2
      prepare_failed="1"
      return 1
    fi
    rm -rf "${mnt}${nsjail_src_dir}"
    mkdir -p "${mnt}/usr/local/src"
    if ! git clone --branch "${NSJAIL_VERSION}" --depth 1 --recurse-submodules --shallow-submodules https://github.com/google/nsjail.git "${mnt}${nsjail_src_dir}" >"${CACHE_ROOT}/nsjail-clone-${key}.log" 2>&1; then
      cat "${CACHE_ROOT}/nsjail-clone-${key}.log" >&2
      echo "failed to clone nsjail source tree ${NSJAIL_VERSION}" >&2
      prepare_failed="1"
      return 1
    fi
    if ! chroot "${mnt}" /usr/bin/make -C "${nsjail_src_dir}" >"${CACHE_ROOT}/nsjail-build-${key}.log" 2>&1; then
      cat "${CACHE_ROOT}/nsjail-build-${key}.log" >&2
      prepare_failed="1"
      return 1
    fi
    install -m 0755 "${mnt}${nsjail_src_dir}/nsjail" "${mnt}/usr/local/bin/nsjail"
  fi

  if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
    case "${PACKAGE_REPO_LAYOUT}" in
      component_packages)
        printf 'deb [trusted=yes] file:/opt/k8s-release-repo/debian ./\n' >"${mnt}/etc/apt/sources.list.d/k8s-release.list"
        ;;
      prebuilt_repo)
        if [[ "${PACKAGE_REPO_TRUSTED}" == "1" ]]; then
          printf 'deb [trusted=yes] file:/opt/k8s-release-repo/debian stable main\n' >"${mnt}/etc/apt/sources.list.d/k8s-release.list"
        else
          if ! chroot "${mnt}" /usr/bin/gpg --dearmor -o /etc/apt/keyrings/k8s-release-apt-keyring.gpg /opt/k8s-release-repo/repo-signing-key.asc; then
            echo "failed to install k8s-release apt keyring inside guest rootfs" >&2
            prepare_failed="1"
            return 1
          fi
          printf 'deb [signed-by=/etc/apt/keyrings/k8s-release-apt-keyring.gpg] file:/opt/k8s-release-repo/debian stable main\n' >"${mnt}/etc/apt/sources.list.d/k8s-release.list"
        fi
        ;;
    esac
  fi
  if [[ -z "${PACKAGE_REPO_ROOT}" || "${PACKAGE_REPO_MODE}" == "hybrid" ]]; then
    if ! chroot "${mnt}" /usr/bin/curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" |
      chroot "${mnt}" /usr/bin/gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
      echo "failed to install Kubernetes apt keyring inside guest rootfs" >&2
      prepare_failed="1"
      return 1
    fi
    printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "${KUBERNETES_MINOR}" >"${mnt}/etc/apt/sources.list.d/kubernetes.list"
  else
    rm -f "${mnt}/etc/apt/sources.list.d/kubernetes.list"
  fi
  if ! chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update >"${CACHE_ROOT}/apt-update-kubernetes-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-update-kubernetes-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi
  local kubernetes_pkg_names=(kubelet kubeadm kubectl)
  local repo_only_pkg_names=()
  local install_kubernetes_args=()
  local package_name=""
  local package_version_pattern=""
  local selected_version=""
  local selected_source=""
  local apt_cache_cmd=""
  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
    kubernetes_pkg_names+=(kube-apiserver kube-controller-manager kube-scheduler)
    repo_only_pkg_names+=(etcd etcdctl)
  fi
  if [[ -n "${KUBERNETES_VERSION}" ]]; then
    package_version_pattern="^${KUBERNETES_VERSION#v}(-|$)"
    for package_name in "${kubernetes_pkg_names[@]}"; do
      selected_version=""
      selected_source=""
      if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
        selected_version="$(
          chroot "${mnt}" /bin/bash -lc "apt-cache madison ${package_name} | awk '\$1 == \"${package_name}\" && \$0 ~ /file:\\/opt\\/k8s-release-repo\\/debian/ && \$3 ~ /${package_version_pattern}/ {print \$3; exit}'"
        )"
        if [[ -n "${selected_version}" ]]; then
          selected_source="k8s-release-repo"
        fi
      fi
      if [[ -z "${selected_version}" && ( -z "${PACKAGE_REPO_ROOT}" || "${PACKAGE_REPO_MODE}" == "hybrid" ) ]]; then
        selected_version="$(
          chroot "${mnt}" /bin/bash -lc "apt-cache madison ${package_name} | awk '\$1 == \"${package_name}\" && \$0 ~ /pkgs.k8s.io/ && \$3 ~ /${package_version_pattern}/ {print \$3; exit}'"
        )"
        if [[ -n "${selected_version}" ]]; then
          selected_source="pkgs.k8s.io"
        fi
      fi
      if [[ -z "${selected_version}" ]]; then
        echo "requested Kubernetes package ${package_name} ${KUBERNETES_VERSION} is not available from the configured repositories" >&2
        chroot "${mnt}" /bin/bash -lc "apt-cache madison ${package_name} | head -n 20" >&2 || true
        prepare_failed="1"
        return 1
      fi
      echo "selected ${package_name} ${selected_version} from ${selected_source}" >&2
      install_kubernetes_args+=("${package_name}=${selected_version}")
    done
  else
    install_kubernetes_args=("${kubernetes_pkg_names[@]}")
  fi
  for package_name in "${repo_only_pkg_names[@]}"; do
    selected_version=""
    if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
      apt_cache_cmd="apt-cache madison ${package_name} | awk '\$1 == \"${package_name}\" && \$0 ~ /file:\\/opt\\/k8s-release-repo\\/debian/ {print \$3; exit}'"
      selected_version="$(chroot "${mnt}" /bin/bash -lc "${apt_cache_cmd}")"
    fi
    if [[ -n "${selected_version}" ]]; then
      echo "selected ${package_name} ${selected_version} from k8s-release-repo" >&2
      install_kubernetes_args+=("${package_name}=${selected_version}")
    elif [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
      echo "required nsjail package ${package_name} is not available from the configured k8s-release repository" >&2
      chroot "${mnt}" /bin/bash -lc "apt-cache madison ${package_name} | head -n 20" >&2 || true
      prepare_failed="1"
      return 1
    else
      install_kubernetes_args+=("${package_name}")
    fi
  done
  if ! DEBIAN_FRONTEND=noninteractive chroot "${mnt}" /usr/bin/apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "${install_kubernetes_args[@]}" >"${CACHE_ROOT}/apt-install-kubernetes-${key}.log" 2>&1; then
    cat "${CACHE_ROOT}/apt-install-kubernetes-${key}.log" >&2
    prepare_failed="1"
    return 1
  fi
  chroot "${mnt}" /usr/bin/apt-mark hold "${kubernetes_pkg_names[@]}" "${repo_only_pkg_names[@]}" >/dev/null 2>&1 || true
  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
    local unit_name=""
    for unit_name in etcd kube-apiserver kube-controller-manager kube-scheduler; do
      systemctl --root="${mnt}" disable "${unit_name}" >/dev/null 2>&1 || true
    done
  fi

  mkdir -p "${CACHE_ROOT}/downloads"
  local cni_archive="${CACHE_ROOT}/downloads/cni-plugins-linux-${cni_arch_value}-${CNI_PLUGINS_VERSION}.tgz"
  mkdir -p "${mnt}/opt/cni/bin"
  if [[ ! -f "${cni_archive}" ]]; then
    if ! curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${cni_arch_value}-${CNI_PLUGINS_VERSION}.tgz" -o "${cni_archive}"; then
      echo "failed to download CNI plugins archive" >&2
      prepare_failed="1"
      return 1
    fi
  fi
  if ! tar -C "${mnt}/opt/cni/bin" -xzf "${cni_archive}"; then
    echo "failed to install CNI plugins inside guest rootfs" >&2
    prepare_failed="1"
    return 1
  fi

  pause_image="$(chroot "${mnt}" /usr/bin/kubeadm config images list 2>/dev/null | awk '/pause/{print $1; exit}')"
  mkdir -p "${mnt}/etc/containerd"
  if ! chroot "${mnt}" /usr/bin/containerd config default >"${mnt}/etc/containerd/config.toml"; then
    echo "failed to render containerd config inside guest rootfs" >&2
    prepare_failed="1"
    return 1
  fi
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${mnt}/etc/containerd/config.toml"
  if [[ "${GUEST_SELINUX_MODE}" == "disabled" ]]; then
    sed -i 's/enable_selinux = true/enable_selinux = false/' "${mnt}/etc/containerd/config.toml" || true
    sed -i 's/enable_selinux = false/enable_selinux = false/' "${mnt}/etc/containerd/config.toml" || true
  else
    sed -i 's/enable_selinux = false/enable_selinux = true/' "${mnt}/etc/containerd/config.toml" || true
  fi
  if [[ -n "${pause_image}" ]]; then
    sed -i "s#sandbox_image = \".*\"#sandbox_image = \"${pause_image}\"#" "${mnt}/etc/containerd/config.toml"
  fi

  if [[ -f "${mnt}/etc/selinux/config" ]]; then
    sed -i "s/^SELINUX=.*/SELINUX=${GUEST_SELINUX_MODE}/" "${mnt}/etc/selinux/config" || true
  fi

  prepare_failed="0"
  mkdir -p "${mnt}/etc/modules-load.d" "${mnt}/etc/sysctl.d" "${mnt}/etc/cloud"
  if [[ -n "${PACKAGE_REPO_ROOT}" ]]; then
    if [[ -x "${mnt}/usr/local/bin/kubelet" && ! -e "${mnt}/usr/bin/kubelet" ]]; then
      mkdir -p "${mnt}/usr/bin"
      ln -sf /usr/local/bin/kubelet "${mnt}/usr/bin/kubelet"
    fi
    mkdir -p "${mnt}/etc/systemd/system/kubelet.service.d"
    cat >"${mnt}/etc/systemd/system/kubelet.service.d/20-k2vm-containerd.conf" <<'EOF'
[Unit]
Requires=
After=
Wants=containerd.service
After=containerd.service
EOF
    cat >"${mnt}/etc/systemd/system/docker.service" <<'EOF'
[Unit]
Description=Compatibility shim for kubelet package expecting docker.service
After=containerd.service
Wants=containerd.service

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
  fi
  cat >"${mnt}/etc/modules-load.d/kubernetes.conf" <<EOF
overlay
br_netfilter
EOF
  cat >"${mnt}/etc/sysctl.d/99-kubernetes.conf" <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
  touch "${mnt}/etc/cloud/cloud-init.disabled" 2>/dev/null || true

  chroot "${mnt}" /usr/bin/update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
  chroot "${mnt}" /usr/bin/update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
  mkdir -p "${mnt}/etc/systemd/system/multi-user.target.wants"
  ln -sf /lib/systemd/system/ssh.service "${mnt}/etc/systemd/system/multi-user.target.wants/ssh.service"
  ln -sf /lib/systemd/system/systemd-networkd.service "${mnt}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"

  if [[ -f "${mnt}/etc/selinux/config" ]] && grep -Eq '^SELINUX=(enforcing|permissive)$' "${mnt}/etc/selinux/config"; then
    if ! chroot "${mnt}" /sbin/setfiles -F /etc/selinux/default/contexts/files/file_contexts / >"${CACHE_ROOT}/selinux-relabel-${key}.log" 2>&1; then
      cat "${CACHE_ROOT}/selinux-relabel-${key}.log" >&2
      prepare_failed="1"
      return 1
    fi
    rm -f "${mnt}/.autorelabel"
  fi
  cleanup_mounts
  trap - RETURN ERR
  mv "${tmp}" "${prepared}"
  PREPARED_ROOTFS_PATH="${prepared}"
}

configure_vm() {
  local idx="$1"
  local vm_dir="$2"
  local ip
  local name
  local mnt
  cleanup_vm_mount() {
    set +e
    if mountpoint -q "${mnt}"; then
      umount "${mnt}" 2>/dev/null || umount -l "${mnt}" 2>/dev/null || true
    fi
  }
  cleanup_vm_mount_return() {
    local status="$?"
    cleanup_vm_mount
    return "${status}"
  }
  ip="$(node_ip "${idx}")"
  name="$(node_name "${idx}")"

  cp --reflink=auto "${PREPARED_ROOTFS_PATH}" "${vm_dir}/rootfs.ext4" 2>/dev/null || cp "${PREPARED_ROOTFS_PATH}" "${vm_dir}/rootfs.ext4"
  e2fsck -fy "${vm_dir}/rootfs.ext4" >/dev/null 2>&1 || true
  mnt="${vm_dir}/mnt"
  mkdir -p "${mnt}"
  mount -o loop "${vm_dir}/rootfs.ext4" "${mnt}"
  trap cleanup_vm_mount_return RETURN

  printf '%s\n' "${name}" >"${mnt}/etc/hostname"
  {
    printf '127.0.0.1 localhost\n'
    printf '127.0.1.1 %s\n' "${name}"
    printf '%s api-lb\n' "${API_LB_IP}"
    for j in $(seq 0 "$((NODE_COUNT - 1))"); do
      printf '%s %s\n' "$(node_ip "${j}")" "$(node_name "${j}")"
    done
  } >"${mnt}/etc/hosts"

  mkdir -p "${mnt}/etc/systemd/network" "${mnt}/etc/systemd/system/multi-user.target.wants" "${mnt}/etc/cloud"
  cat >"${mnt}/etc/systemd/network/20-eth0.network" <<EOF
[Match]
Name=eth0

[Network]
Address=${ip}/24
Gateway=${GATEWAY}
DNS=1.1.1.1
DNS=8.8.8.8
EOF

  rm -f "${mnt}/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"${mnt}/etc/resolv.conf"
  rm -f "${mnt}/etc/machine-id" 2>/dev/null || true
  mkdir -p "${mnt}/var/lib/dbus"
  ln -sfn /etc/machine-id "${mnt}/var/lib/dbus/machine-id"
  : >"${mnt}/etc/machine-id"
  rm -rf "${mnt}/etc/kubernetes" "${mnt}/var/lib/etcd" "${mnt}/var/lib/cni" "${mnt}/var/lib/kubelet" "${mnt}/var/lib/containerd" "${mnt}/etc/cni/net.d"
  mkdir -p "${mnt}/var/lib/containerd" "${mnt}/etc/cni/net.d"
  touch "${mnt}/etc/cloud/cloud-init.disabled" 2>/dev/null || true
  ln -sf /lib/systemd/system/ssh.service "${mnt}/etc/systemd/system/multi-user.target.wants/ssh.service"
  ln -sf /lib/systemd/system/systemd-networkd.service "${mnt}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  if [[ -f "${mnt}/etc/selinux/config" ]] && grep -Eq '^SELINUX=(enforcing|permissive)$' "${mnt}/etc/selinux/config"; then
    if ! chroot "${mnt}" /sbin/setfiles -F /etc/selinux/default/contexts/files/file_contexts /etc /var /root >"${vm_dir}/selinux-relabel.log" 2>&1; then
      cat "${vm_dir}/selinux-relabel.log" >&2
      return 1
    fi
  fi

  cleanup_vm_mount
  trap - RETURN
}

boot_node() {
  local idx="$1"
  local vm_dir="${RUN_ROOT}/nodes/node${idx}"
  local tap
  local mac
  local mem
  tap="$(node_tap "${idx}")"
  mac="$(node_mac "${idx}")"
  mem="$(node_mem "${idx}")"

  mkdir -p "${vm_dir}"
  configure_vm "${idx}" "${vm_dir}"
  ip tuntap add dev "${tap}" mode tap 2>/dev/null || true
  ip link set "${tap}" master "${BRIDGE_NAME}"
  ip link set "${tap}" up

  if [[ -n "${INITRD_PATH}" ]]; then
    cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","initrd_path":"${INITRD_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF
  else
    cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF
  fi
  "${FIRECRACKER_BIN}" --api-sock "${vm_dir}/fc.sock" --config-file "${vm_dir}/vm.json" >"${vm_dir}/console.log" 2>&1 &
  echo $! >"${vm_dir}/pid"
}

setup_bridge() {
  ip link add name "${BRIDGE_NAME}" type bridge 2>/dev/null || true
  ip addr add "${GATEWAY}/24" dev "${BRIDGE_NAME}" 2>/dev/null || true
  ip addr add "${API_LB_IP}/24" dev "${BRIDGE_NAME}" 2>/dev/null || true
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

setup_api_lb() {
  local cfg="${RUN_ROOT}/haproxy.cfg"
  mkdir -p "${RUN_ROOT}"
  docker rm -f "${API_LB_CONTAINER_NAME}" >/dev/null 2>&1 || true
  {
    printf 'global\n'
    printf '  maxconn 2048\n'
    printf 'defaults\n'
    printf '  mode tcp\n'
    printf '  timeout connect 5s\n'
    printf '  timeout client 60s\n'
    printf '  timeout server 60s\n'
    printf 'frontend kube_api\n'
    printf '  bind %s:%s\n' "${API_LB_IP}" "${API_LB_PORT}"
    printf '  default_backend kube_apis\n'
    printf 'backend kube_apis\n'
    printf '  balance roundrobin\n'
    printf '  option tcp-check\n'
    printf '  default-server inter 2s fall 3 rise 2\n'
    for i in $(seq 0 "$((CONTROL_PLANE_COUNT - 1))"); do
      printf '  server cp%d %s:6443 check\n' "${i}" "$(node_ip "${i}")"
    done
  } >"${cfg}"
  docker run -d --name "${API_LB_CONTAINER_NAME}" --network host -v "${cfg}:/usr/local/etc/haproxy/haproxy.cfg:ro" "${HAPROXY_IMAGE}" >/dev/null
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

prepare_host_kubectl() {
  local kubectl_deb=""
  local extracted_bin=""
  mkdir -p "${HOST_TOOLS_DIR}" "${ARTIFACT_DIR}"
  if command -v kubectl >/dev/null 2>&1; then
    HOST_KUBECTL_BIN="$(command -v kubectl)"
    return 0
  fi
  if [[ -x "${HOST_KUBECTL_BIN}" ]]; then
    return 0
  fi
  [[ -n "${PACKAGE_REPO_ROOT}" ]] || {
    echo "PACKAGE_REPO_ROOT is required to prepare host kubectl" >&2
    return 1
  }
  kubectl_deb="$(find "${PACKAGE_REPO_ROOT}/debian" -maxdepth 1 -type f -name 'kubectl_*.deb' | sort | tail -n1)"
  [[ -n "${kubectl_deb}" ]] || {
    echo "failed to locate kubectl package under ${PACKAGE_REPO_ROOT}/debian" >&2
    return 1
  }
  rm -rf "${HOST_KUBECTL_ROOT}"
  mkdir -p "${HOST_KUBECTL_ROOT}"
  dpkg-deb -x "${kubectl_deb}" "${HOST_KUBECTL_ROOT}"
  extracted_bin="$(find "${HOST_KUBECTL_ROOT}" -type f -name kubectl | sort | head -n1)"
  [[ -n "${extracted_bin}" && -x "${extracted_bin}" ]] || {
    echo "failed to extract kubectl from ${kubectl_deb}" >&2
    return 1
  }
  ln -sf "${extracted_bin}" "${HOST_TOOLS_DIR}/kubectl"
}

export_host_kubeconfig() {
  local tmp_path="${HOST_KUBECONFIG_PATH}.tmp"
  mkdir -p "${HOST_TOOLS_DIR}" "${ARTIFACT_DIR}"
  copy_guest_file "/etc/kubernetes/admin.conf" "${tmp_path}"
  [[ -s "${tmp_path}" ]] || {
    echo "failed to copy /etc/kubernetes/admin.conf from the primary control plane" >&2
    rm -f "${tmp_path}"
    return 1
  }
  mv "${tmp_path}" "${HOST_KUBECONFIG_PATH}"
  chmod 600 "${HOST_KUBECONFIG_PATH}"
}

host_kubectl() {
  [[ -x "${HOST_KUBECTL_BIN}" ]] || {
    echo "host kubectl is not prepared: ${HOST_KUBECTL_BIN}" >&2
    return 1
  }
  [[ -s "${HOST_KUBECONFIG_PATH}" ]] || {
    echo "host kubeconfig is missing: ${HOST_KUBECONFIG_PATH}" >&2
    return 1
  }
  KUBECONFIG="${HOST_KUBECONFIG_PATH}" "${HOST_KUBECTL_BIN}" "$@"
}

prepare_node_runtime() {
  local idx="$1"
  node_ssh "${idx}" "cat >/root/prepare-node.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab 2>/dev/null || true
modprobe overlay || true
modprobe br_netfilter || true
sysctl --system >/dev/null
systemctl daemon-reload || true
systemctl enable --now ssh containerd kubelet >/dev/null 2>&1 || true
systemctl restart containerd
kubeadm reset -f >/dev/null 2>&1 || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/cni /var/lib/kubelet/* /etc/cni/net.d/*
mkdir -p /etc/cni/net.d
kubeadm config images pull --kubernetes-version="$(kubeadm version -o short)" >/dev/null 2>&1 || true
EOF
  node_ssh "${idx}" "chmod +x /root/prepare-node.sh && /root/prepare-node.sh"
}

migrate_control_plane_node_to_nsjail() {
  local idx="$1"
  local name
  name="$(node_name "${idx}")"

node_ssh "${idx}" "cat >/root/migrate-control-plane-to-nsjail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ETCDCTL_BIN="${ETCDCTL_BIN:-$(command -v etcdctl 2>/dev/null || true)}"
if [[ -z "${ETCDCTL_BIN}" ]]; then
  ETCDCTL_BIN="/usr/local/bin/etcdctl"
fi

components=(etcd kube-apiserver kube-controller-manager kube-scheduler)
backup_dir="/etc/kubernetes/manifests.static-pods"
runtime_dir="/etc/kubernetes/nsjail"
script_dir="/usr/local/sbin"
log_dir="/var/log/nsjail-k8s"
rollback_needed="1"

rollback() {
  local comp=""
  set +e
  for comp in "${components[@]}"; do
    systemctl stop "k2vm-${comp}-nsjail.service" >/dev/null 2>&1 || true
    systemctl disable "k2vm-${comp}-nsjail.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/k2vm-${comp}-nsjail.service" "${script_dir}/run-${comp}-nsjail.sh"
    if [[ -f "${backup_dir}/${comp}.yaml" && ! -f "/etc/kubernetes/manifests/${comp}.yaml" ]]; then
      mv "${backup_dir}/${comp}.yaml" "/etc/kubernetes/manifests/${comp}.yaml"
    fi
  done
  systemctl daemon-reload || true
  systemctl start kubelet >/dev/null 2>&1 || true
}

trap 'if [[ "${rollback_needed}" == "1" ]]; then rollback; fi' ERR

mkdir -p "${backup_dir}" "${runtime_dir}" "${script_dir}" "${log_dir}" /etc/systemd/system

echo "[stage] render-nsjail-units" >&2
python3 - <<'PY'
import pathlib
import shlex
import shutil
import yaml

components = [
    ("etcd", [], ["network-online.target"], ["network-online.target"]),
    ("kube-apiserver", ["k2vm-etcd-nsjail.service"], ["network-online.target", "k2vm-etcd-nsjail.service"], ["network-online.target", "k2vm-etcd-nsjail.service"]),
    ("kube-controller-manager", ["k2vm-kube-apiserver-nsjail.service"], ["k2vm-kube-apiserver-nsjail.service"], ["k2vm-kube-apiserver-nsjail.service"]),
    ("kube-scheduler", ["k2vm-kube-apiserver-nsjail.service"], ["k2vm-kube-apiserver-nsjail.service"], ["k2vm-kube-apiserver-nsjail.service"]),
]
manifests_dir = pathlib.Path("/etc/kubernetes/manifests")
script_dir = pathlib.Path("/usr/local/sbin")
log_dir = pathlib.Path("/var/log/nsjail-k8s")
unit_dir = pathlib.Path("/etc/systemd/system")
nsjail_bin = pathlib.Path("/usr/local/bin/nsjail")
if not nsjail_bin.exists():
    raise SystemExit("nsjail binary is missing at /usr/local/bin/nsjail")

nsjail_base = [
    str(nsjail_bin),
    "-Mo",
    "--time_limit", "0",
    "--disable_rlimits",
    "--chroot", "/",
    "--rw",
    "--keep_env",
    "--keep_caps",
    "--disable_clone_newnet",
    "--disable_clone_newuser",
    "--disable_clone_newcgroup",
]

for component, requires, after, wants in components:
    manifest_path = manifests_dir / f"{component}.yaml"
    if not manifest_path.exists():
        raise SystemExit(f"missing kubeadm manifest: {manifest_path}")
    data = yaml.safe_load(manifest_path.read_text())
    container = data["spec"]["containers"][0]
    command = list(container.get("command") or [])
    command.extend(container.get("args") or [])
    if not command:
        raise SystemExit(f"manifest has no command array: {manifest_path}")
    if not command[0].startswith("/"):
        resolved = shutil.which(command[0], path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        if not resolved:
            raise SystemExit(f"unable to resolve host binary for {component}: {command[0]}")
        command[0] = resolved
    env_pairs = [(item["name"], item.get("value", "")) for item in container.get("env", [])]
    wrapper_path = script_dir / f"run-{component}-nsjail.sh"
    wrapper_lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]
    for key, value in env_pairs:
        wrapper_lines.append(f"export {key}={shlex.quote(value)}")
    nsjail_cmd = nsjail_base + ["--log", str(log_dir / f"{component}.log"), "--"] + command
    wrapper_lines.append("exec " + " ".join(shlex.quote(item) for item in nsjail_cmd))
    wrapper_path.write_text("\n".join(wrapper_lines) + "\n")
    wrapper_path.chmod(0o755)

    unit_name = f"k2vm-{component}-nsjail.service"
    unit_lines = [
        "[Unit]",
        f"Description=Kubernetes {component} under nsjail",
    ]
    if after:
        unit_lines.append("After=" + " ".join(after))
    if wants:
        unit_lines.append("Wants=" + " ".join(wants))
    if requires:
        unit_lines.append("Requires=" + " ".join(requires))
    unit_lines.extend(
        [
            "",
            "[Service]",
            "Type=simple",
            f"ExecStart={wrapper_path}",
            "Restart=always",
            "RestartSec=5",
            "TimeoutStopSec=30",
            "KillMode=mixed",
            "LimitNOFILE=40000",
            "",
            "[Install]",
            "WantedBy=multi-user.target",
        ]
    )
    (unit_dir / unit_name).write_text("\n".join(unit_lines) + "\n")
PY

echo "[stage] stop-kubelet" >&2
systemctl stop kubelet >/dev/null 2>&1 || true

echo "[stage] move-static-manifests" >&2
for comp in "${components[@]}"; do
  if [[ -f "/etc/kubernetes/manifests/${comp}.yaml" ]]; then
    mv "/etc/kubernetes/manifests/${comp}.yaml" "${backup_dir}/${comp}.yaml"
  fi
done

kill_pid_and_task() {
  local pid="$1"
  local task_id=""
  [[ -n "${pid}" ]] || return 0
  if command -v ctr >/dev/null 2>&1; then
    while IFS= read -r task_id; do
      [[ -n "${task_id}" ]] || continue
      ctr -n k8s.io tasks kill -s SIGKILL "${task_id}" >/dev/null 2>&1 || true
      ctr -n k8s.io tasks rm -f "${task_id}" >/dev/null 2>&1 || true
      ctr -n k8s.io containers rm "${task_id}" >/dev/null 2>&1 || true
    done < <(ctr -n k8s.io tasks ls 2>/dev/null | awk -v pid="${pid}" '$2 == pid {print $1}')
  fi
  kill -TERM "${pid}" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL "${pid}" >/dev/null 2>&1 || true
}

echo "[stage] terminate-static-control-plane" >&2
pkill -f '(^|/)etcd($| )' >/dev/null 2>&1 || true
pkill -f 'kube-apiserver' >/dev/null 2>&1 || true
pkill -f 'kube-controller-manager' >/dev/null 2>&1 || true
pkill -f 'kube-scheduler' >/dev/null 2>&1 || true
while IFS= read -r pid; do
  kill_pid_and_task "${pid}"
done < <(ss -lntpH | grep -E ':(2379|2380|6443|10257|10259)[[:space:]]' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
sleep 2

systemctl daemon-reload

wait_port_clear() {
  local port="$1"
  local pid=""
  for _ in $(seq 1 60); do
    if ! ss -lntH "( sport = :${port} )" | grep -q .; then
      return 0
    fi
    while IFS= read -r pid; do
      kill_pid_and_task "${pid}"
    done < <(ss -lntpH "( sport = :${port} )" | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
    sleep 2
  done
  return 1
}

echo "[stage] wait-old-ports-clear" >&2
for port in 2379 2380 6443 10257 10259; do
  wait_port_clear "${port}"
done

echo "[stage] start-nsjail-etcd" >&2
systemctl enable --now k2vm-etcd-nsjail.service >/dev/null
etcd_ready="0"
for _ in $(seq 1 60); do
  if ETCDCTL_API=3 "${ETCDCTL_BIN}" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    endpoint health >/dev/null 2>&1; then
    etcd_ready="1"
    break
  fi
  sleep 2
done
[[ "${etcd_ready}" == "1" ]]

echo "[stage] start-nsjail-apiserver" >&2
systemctl enable --now k2vm-kube-apiserver-nsjail.service >/dev/null
api_ready="0"
for _ in $(seq 1 60); do
  if curl -ksSf https://127.0.0.1:6443/readyz >/dev/null 2>&1; then
    api_ready="1"
    break
  fi
  sleep 2
done
[[ "${api_ready}" == "1" ]]

echo "[stage] start-nsjail-controllers" >&2
systemctl enable --now k2vm-kube-controller-manager-nsjail.service >/dev/null
systemctl enable --now k2vm-kube-scheduler-nsjail.service >/dev/null
for unit in k2vm-etcd-nsjail.service k2vm-kube-apiserver-nsjail.service k2vm-kube-controller-manager-nsjail.service k2vm-kube-scheduler-nsjail.service; do
  systemctl is-active --quiet "${unit}"
done

echo "[stage] verify-nsjail-runtime" >&2
python3 - <<'PY'
import pathlib
import subprocess

components = ["etcd", "kube-apiserver", "kube-controller-manager", "kube-scheduler"]

for component in components:
    unit = f"k2vm-{component}-nsjail.service"
    main_pid = subprocess.check_output(
        ["systemctl", "show", "-p", "MainPID", "--value", unit],
        text=True,
    ).strip()
    if not main_pid or main_pid == "0":
        raise SystemExit(f"{unit} has no MainPID")
    cmdline = subprocess.check_output(["ps", "-p", main_pid, "-o", "cmd="], text=True).strip()
    if "nsjail" not in cmdline:
        raise SystemExit(f"{unit} is not running under nsjail: {cmdline}")
    component_mnt_ns = pathlib.Path(f"/proc/{main_pid}/ns/mnt").readlink()
    component_pid_ns = pathlib.Path(f"/proc/{main_pid}/ns/pid").readlink()
    print(component, main_pid, component_mnt_ns, component_pid_ns)
PY

echo "[stage] restart-kubelet" >&2
systemctl start kubelet >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true

rollback_needed="0"
trap - ERR
EOF
  node_ssh "${idx}" "chmod +x /root/migrate-control-plane-to-nsjail.sh && /root/migrate-control-plane-to-nsjail.sh" >"${RUN_ROOT}/nsjail-migrate-${name}.log" 2>&1
}

migrate_control_planes_to_nsjail() {
  if [[ "${CONTROL_PLANE_RUNTIME}" != "nsjail" ]]; then
    return 0
  fi

  local order=()
  local i
  for i in $(seq 1 "$((CONTROL_PLANE_COUNT - 1))"); do
    order+=("${i}")
  done
  order+=(0)

  for i in "${order[@]}"; do
    migrate_control_plane_node_to_nsjail "${i}"
    wait_for_node_ready "$(node_name "${i}")"
    wait_for_cluster
  done
}

wait_for_flannel() {
  local flannel_ns=""
  for _ in $(seq 1 180); do
    flannel_ns="$(host_kubectl get daemonset -A --no-headers 2>/dev/null | awk '$2=="kube-flannel-ds"{print $1; exit}' || true)"
    if [[ -n "${flannel_ns}" ]]; then
      if host_kubectl -n "${flannel_ns}" rollout status daemonset/kube-flannel-ds --timeout=5s >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

install_network_plugin() {
  if [[ "${NETWORK_PLUGIN}" == "flannel" ]]; then
    server_ssh "kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f $(printf '%q' "${FLANNEL_MANIFEST_URL}")"
    wait_for_flannel
    return 0
  fi

  server_ssh "cat >/root/install-network-plugin.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
network_plugin="${NETWORK_PLUGIN:?}"
artifact_prefix="${ARTIFACT_PREFIX:?}"

case "${network_plugin}" in
  cilium)
    cli_version="${CILIUM_CLI_VERSION:-}"
    case "$(uname -m)" in
      x86_64) cli_arch=amd64 ;;
      aarch64) cli_arch=arm64 ;;
      *)
        echo "unsupported Cilium CLI architecture: $(uname -m)" >&2
        exit 1
        ;;
    esac
    if [[ -z "${cli_version}" ]]; then
      cli_version="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
    fi
    cache_dir="/var/cache/cilium-cli/${cli_version}"
    archive="${cache_dir}/cilium-linux-${cli_arch}.tar.gz"
    sumfile="${archive}.sha256sum"
    mkdir -p "${cache_dir}"
    if [[ ! -f "${archive}" || ! -f "${sumfile}" ]]; then
      curl -L --fail "https://github.com/cilium/cilium-cli/releases/download/${cli_version}/cilium-linux-${cli_arch}.tar.gz" -o "${archive}"
      curl -L --fail "https://github.com/cilium/cilium-cli/releases/download/${cli_version}/cilium-linux-${cli_arch}.tar.gz.sha256sum" -o "${sumfile}"
    fi
    (
      cd "${cache_dir}"
      sha256sum --check "$(basename "${sumfile}")"
    )
    tar xzvfC "${archive}" /usr/local/bin >/dev/null
    cilium install \
      --version "${CILIUM_VERSION}" \
      --wait \
      --wait-duration 10m \
      --set ipam.mode=kubernetes \
      --set k8s.requireIPv4PodCIDR=true \
      --set kubeProxyReplacement=false \
      --set k8sServiceHost="${API_LB_IP}" \
      --set k8sServicePort="${API_LB_PORT}"
    cilium status --wait --wait-duration 10m --interactive=false > "${artifact_prefix}.cilium-status" 2>&1
    kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get pods -l k8s-app=cilium -o wide > "${artifact_prefix}.cilium-pods" 2>&1 || true
    ;;
  *)
    echo "unsupported network plugin: ${network_plugin}" >&2
    exit 1
    ;;
esac
EOF
  server_ssh "chmod +x /root/install-network-plugin.sh && NETWORK_PLUGIN=$(printf '%q' "${NETWORK_PLUGIN}") CILIUM_VERSION=$(printf '%q' "${CILIUM_VERSION}") CILIUM_CLI_VERSION=$(printf '%q' "${CILIUM_CLI_VERSION}") API_LB_IP=$(printf '%q' "${API_LB_IP}") API_LB_PORT=$(printf '%q' "${API_LB_PORT}") ARTIFACT_PREFIX=$(printf '%q' "${ARTIFACT_PREFIX}") /root/install-network-plugin.sh" >"${RUN_ROOT}/network-plugin-install.log" 2>&1
}

init_primary_control_plane() {
  server_ssh "cat >/root/init-primary.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
version="${KUBERNETES_VERSION:-\$(kubeadm version -o short)}"
kubeadm init \
  --kubernetes-version "\${version}" \
  --control-plane-endpoint "${API_LB_ENDPOINT}" \
  --apiserver-advertise-address "${PRIMARY_CONTROL_PLANE_IP}" \
  --pod-network-cidr "${POD_CIDR}" \
  --service-cidr "${SERVICE_CIDR}" \
  --upload-certs \
  --ignore-preflight-errors=all
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
certificate_key="\$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1)"
join_cmd="\$(kubeadm token create --print-join-command)"
printf '%s\n' "\${certificate_key}" >/root/certificate-key.txt
printf '%s\n' "\${join_cmd}" >/root/join-command.txt
EOF
  server_ssh "chmod +x /root/init-primary.sh && /root/init-primary.sh" >"${RUN_ROOT}/kubeadm-init.log" 2>&1
  export_host_kubeconfig
  install_network_plugin
}

wait_for_node_ready() {
  local name="$1"
  for _ in $(seq 1 240); do
    if host_kubectl get node "${name}" --no-headers 2>/dev/null | awk '$2=="Ready"{ok=1} END{exit(ok?0:1)}'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

join_additional_control_planes() {
  local join_cmd
  local certificate_key
  join_cmd="$(server_ssh "cat /root/join-command.txt")"
  certificate_key="$(server_ssh "cat /root/certificate-key.txt")"
  [[ -n "${join_cmd}" && -n "${certificate_key}" ]] || {
    echo "failed to retrieve kubeadm join material from primary control plane" >&2
    exit 1
  }

  for i in $(seq 1 "$((CONTROL_PLANE_COUNT - 1))"); do
    local ip
    local name
    ip="$(node_ip "${i}")"
    name="$(node_name "${i}")"
    node_ssh "${i}" "cat >/root/join-control-plane.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${join_cmd} --control-plane --certificate-key ${certificate_key} --apiserver-advertise-address ${ip} --ignore-preflight-errors=all
EOF
    node_ssh "${i}" "chmod +x /root/join-control-plane.sh && /root/join-control-plane.sh" >"${RUN_ROOT}/kubeadm-join-control-plane-${i}.log" 2>&1
    wait_for_node_ready "${name}"
  done
}

join_workers() {
  if (( WORKER_COUNT == 0 )); then
    return 0
  fi
  local join_cmd
  join_cmd="$(server_ssh "cat /root/join-command.txt")"
  for i in $(seq "${CONTROL_PLANE_COUNT}" "$((NODE_COUNT - 1))"); do
    local name
    name="$(node_name "${i}")"
    node_ssh "${i}" "cat >/root/join-worker.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${join_cmd} --ignore-preflight-errors=all
EOF
    node_ssh "${i}" "chmod +x /root/join-worker.sh && /root/join-worker.sh" >"${RUN_ROOT}/kubeadm-join-worker-${i}.log" 2>&1
    wait_for_node_ready "${name}"
  done
}

snapshot_cluster_status() {
  mkdir -p "${ARTIFACT_DIR}"
  host_kubectl get nodes -o wide >"${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
  host_kubectl get nodes --no-headers >"${ARTIFACT_DIR}/nodes-plain.txt" 2>&1 || true
  host_kubectl get pods -A -o wide >"${ARTIFACT_DIR}/pods.txt" 2>&1 || true
  host_kubectl get svc -A -o wide >"${ARTIFACT_DIR}/services.txt" 2>&1 || true
  host_kubectl get endpoints kubernetes -o wide >"${ARTIFACT_DIR}/apiserver-endpoints.txt" 2>&1 || true
}

wait_for_cluster() {
  local ready_count="0"
  local control_plane_ready="0"
  local endpoint_count="0"
  for _ in $(seq 1 240); do
    snapshot_cluster_status
    ready_count="$(awk '$2=="Ready"{c++} END{print c+0}' "${ARTIFACT_DIR}/nodes-plain.txt" 2>/dev/null || echo 0)"
    control_plane_ready="$(awk '$2=="Ready" && $3 ~ /control-plane/ {c++} END{print c+0}' "${ARTIFACT_DIR}/nodes-plain.txt" 2>/dev/null || echo 0)"
    endpoint_count="$(host_kubectl get endpoints kubernetes -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | awk 'NF{c++} END{print c+0}' || echo 0)"
    if [[ "${ready_count}" -ge "${NODE_COUNT}" && "${control_plane_ready}" -ge "${CONTROL_PLANE_COUNT}" && "${endpoint_count}" -ge "${CONTROL_PLANE_COUNT}" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

verify_cluster_version() {
  if [[ -z "${KUBERNETES_VERSION}" ]]; then
    return 0
  fi
  local versions=""
  versions="$(host_kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "${versions}" ]] || {
    echo "failed to read cluster node versions" >&2
    return 1
  }
  while IFS= read -r version; do
    [[ -n "${version}" ]] || continue
    if [[ "${version}" != "${KUBERNETES_VERSION}" ]]; then
      echo "cluster version mismatch: expected ${KUBERNETES_VERSION}, got ${version}" >&2
      printf '%s\n' "${versions}" >&2
      return 1
    fi
  done <<<"${versions}"
}

rebalance_coredns() {
  host_kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
  host_kubectl -n kube-system rollout status deployment/coredns --timeout=240s >/dev/null 2>&1 || true
}

capture_etcd_members() {
  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
    local i=""
    mkdir -p "${ARTIFACT_DIR}"
    for i in $(seq 0 "$((CONTROL_PLANE_COUNT - 1))"); do
      if ssh "${SSH_OPTS[@]}" "root@$(node_ip "${i}")" true >/dev/null 2>&1; then
        ssh "${SSH_OPTS[@]}" "root@$(node_ip "${i}")" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key member list -w table" >"${ARTIFACT_DIR}/etcd-members.txt" 2>&1 || true
        ssh "${SSH_OPTS[@]}" "root@$(node_ip "${i}")" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint status -w table" >"${ARTIFACT_DIR}/etcd-endpoints.txt" 2>&1 || true
        return 0
      fi
    done
    return
  fi

  local etcd_pod="etcd-$(node_name 0)"
  mkdir -p "${ARTIFACT_DIR}"
  host_kubectl -n kube-system exec "${etcd_pod}" -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key member list -w table >"${ARTIFACT_DIR}/etcd-members.txt" 2>&1 || true
  host_kubectl -n kube-system exec "${etcd_pod}" -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint status -w table >"${ARTIFACT_DIR}/etcd-endpoints.txt" 2>&1 || true
}

run_smoke() {
  mkdir -p "${ARTIFACT_DIR}"
  host_kubectl create namespace smoke --dry-run=client -o yaml | host_kubectl apply -f -
  cat <<'YAML' | host_kubectl apply -f -
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
  host_kubectl -n smoke rollout status daemonset/node-smoke --timeout=240s
  host_kubectl -n smoke rollout status deployment/echo --timeout=240s
  host_kubectl -n kube-system rollout status deployment/coredns --timeout=240s
  cat <<'YAML' | host_kubectl apply -f -
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
  host_kubectl -n smoke wait --for=condition=complete job/dns-http --timeout=240s
  snapshot_cluster_status
  host_kubectl -n smoke get pods -o wide >"${ARTIFACT_DIR}/smoke-pods.txt" 2>&1
  host_kubectl -n smoke get svc echo -o wide >"${ARTIFACT_DIR}/smoke-service.txt" 2>&1
  host_kubectl -n smoke logs job/dns-http >"${ARTIFACT_DIR}/smoke-job.log" 2>&1
  host_kubectl config view --raw >"${ARTIFACT_DIR}/kubeconfig.yaml" 2>&1
}

install_istio_addon() {
  if [[ "${INSTALL_ISTIO}" != "1" ]]; then
    return 0
  fi
  [[ -x "${ISTIOCTL_BIN}" ]] || {
    echo "ISTIOCTL_BIN is not executable: ${ISTIOCTL_BIN}" >&2
    return 1
  }
  mkdir -p "${ARTIFACT_DIR}"
  [[ -s "${HOST_KUBECONFIG_PATH}" ]] || {
    echo "failed to prepare host kubeconfig for Istio installation" >&2
    return 1
  }
  host_kubectl create namespace istio-system --dry-run=client -o yaml | host_kubectl apply -f - >"${RUN_ROOT}/istio-namespace.log" 2>&1
  "${ISTIOCTL_BIN}" manifest generate --set "profile=${ISTIO_PROFILE}" --set "hub=registry.istio.io/release" --set "tag=${ISTIO_VERSION}" >"${RUN_ROOT}/istio-manifest.yaml"
  host_kubectl apply -f "${RUN_ROOT}/istio-manifest.yaml" >"${RUN_ROOT}/istio-install.log" 2>&1
  "${ISTIOCTL_BIN}" version --kubeconfig "${HOST_KUBECONFIG_PATH}" >"${ARTIFACT_DIR}/istioctl-version.txt" 2>&1 || true
  # This lab is intentionally control-plane only by default. Make Istiod schedulable
  # there and lower its requests so it fits on the small Firecracker nodes.
  host_kubectl -n istio-system patch deployment istiod --type=json -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}},{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}}]' >"${RUN_ROOT}/istio-tolerations.log" 2>&1
  host_kubectl -n istio-system patch deployment istiod --type=strategic -p='{"spec":{"template":{"spec":{"containers":[{"name":"discovery","resources":{"requests":{"cpu":"100m","memory":"512Mi"},"limits":{"cpu":"500m","memory":"1Gi"}}}]}}}}' >"${RUN_ROOT}/istio-resources.log" 2>&1
  host_kubectl -n istio-system rollout status deployment/istiod --timeout=240s >"${RUN_ROOT}/istio-rollout.log" 2>&1
  test "$(host_kubectl -n istio-system get deployment istiod -o jsonpath='{.status.availableReplicas}')" = "1"
  host_kubectl -n istio-system get pods -o wide >"${ARTIFACT_DIR}/istio-pods.txt" 2>&1
}

verify_api_lb() {
  for _ in $(seq 1 60); do
    if curl -ksSf --max-time 5 "https://${API_LB_ENDPOINT}/version" >"${RUN_ROOT}/api-lb-version.json" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

collect_diagnostics() {
  mkdir -p "${RUN_ROOT}/artifacts"
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    local dir="${RUN_ROOT}/nodes/node${i}"
    local node_artifacts="${RUN_ROOT}/artifacts/node${i}"
    local ip
    ip="$(node_ip "${i}")"
    mkdir -p "${node_artifacts}"
    [[ -f "${dir}/console.log" ]] && cp "${dir}/console.log" "${node_artifacts}/console.log"
    [[ -f "${dir}/firecracker.log" ]] && cp "${dir}/firecracker.log" "${node_artifacts}/firecracker.log"
    if ssh "${SSH_OPTS[@]}" "root@${ip}" true >/dev/null 2>&1; then
      ssh "${SSH_OPTS[@]}" "root@${ip}" "uname -a" >"${node_artifacts}/uname.txt" 2>&1 || true
      ssh "${SSH_OPTS[@]}" "root@${ip}" "ip addr show" >"${node_artifacts}/ip-addr.txt" 2>&1 || true
      ssh "${SSH_OPTS[@]}" "root@${ip}" "ip route show" >"${node_artifacts}/ip-route.txt" 2>&1 || true
      ssh "${SSH_OPTS[@]}" "root@${ip}" "journalctl -u containerd -u kubelet --no-pager -n 200 || true" >"${node_artifacts}/services.log" 2>&1 || true
      ssh "${SSH_OPTS[@]}" "root@${ip}" "test -f /etc/kubernetes/admin.conf && kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A -o wide || true" >"${node_artifacts}/pods.txt" 2>&1 || true
      if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" && "${i}" -lt "${CONTROL_PLANE_COUNT}" ]]; then
        ssh "${SSH_OPTS[@]}" "root@${ip}" "systemctl list-units 'k2vm-*-nsjail.service' --no-pager --all || true" >"${node_artifacts}/nsjail-services.txt" 2>&1 || true
        ssh "${SSH_OPTS[@]}" "root@${ip}" "ps -eo pid,ppid,cmd | grep '[n]sjail' || true" >"${node_artifacts}/nsjail-processes.txt" 2>&1 || true
        ssh "${SSH_OPTS[@]}" "root@${ip}" "python3 - <<'PY'\nimport pathlib\nimport subprocess\ncomponents = ['etcd', 'kube-apiserver', 'kube-controller-manager', 'kube-scheduler']\nhost_mnt = pathlib.Path('/proc/1/ns/mnt').readlink()\nprint('host_mnt', host_mnt)\nfor comp in components:\n    unit = f'k2vm-{comp}-nsjail.service'\n    pid = subprocess.check_output(['systemctl', 'show', '-p', 'MainPID', '--value', unit], text=True).strip()\n    print(comp, 'pid', pid, 'mnt', pathlib.Path(f'/proc/{pid}/ns/mnt').readlink(), 'pidns', pathlib.Path(f'/proc/{pid}/ns/pid').readlink())\nPY" >"${node_artifacts}/nsjail-namespaces.txt" 2>&1 || true
        ssh "${SSH_OPTS[@]}" "root@${ip}" "ls -1 /etc/kubernetes/manifests.static-pods 2>/dev/null || true" >"${node_artifacts}/nsjail-manifests.txt" 2>&1 || true
      fi
    fi
  done
}

collect_artifacts() {
  mkdir -p "${ARTIFACT_DIR}"
  [[ -f "${ARTIFACT_DIR}/nodes.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.nodes" "${ARTIFACT_DIR}/nodes.txt"
  [[ -f "${ARTIFACT_DIR}/pods.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.pods" "${ARTIFACT_DIR}/pods.txt"
  [[ -f "${ARTIFACT_DIR}/services.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.services" "${ARTIFACT_DIR}/services.txt"
  [[ -f "${ARTIFACT_DIR}/apiserver-endpoints.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.apiserver-endpoints" "${ARTIFACT_DIR}/apiserver-endpoints.txt"
  [[ -f "${ARTIFACT_DIR}/etcd-members.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.etcd-members" "${ARTIFACT_DIR}/etcd-members.txt"
  [[ -f "${ARTIFACT_DIR}/etcd-endpoints.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.etcd-endpoints" "${ARTIFACT_DIR}/etcd-endpoints.txt"
  [[ -f "${ARTIFACT_DIR}/smoke-pods.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.smoke-pods" "${ARTIFACT_DIR}/smoke-pods.txt"
  [[ -f "${ARTIFACT_DIR}/smoke-service.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.smoke-service" "${ARTIFACT_DIR}/smoke-service.txt"
  [[ -f "${ARTIFACT_DIR}/smoke-job.log" ]] || copy_guest_file "${ARTIFACT_PREFIX}.smoke-job.log" "${ARTIFACT_DIR}/smoke-job.log"
  [[ -f "${ARTIFACT_DIR}/cilium-status.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.cilium-status" "${ARTIFACT_DIR}/cilium-status.txt"
  [[ -f "${ARTIFACT_DIR}/cilium-pods.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.cilium-pods" "${ARTIFACT_DIR}/cilium-pods.txt"
  [[ -f "${ARTIFACT_DIR}/cilium-connectivity.log" ]] || copy_guest_file "${ARTIFACT_PREFIX}.cilium-connectivity.log" "${ARTIFACT_DIR}/cilium-connectivity.log"
  [[ -f "${ARTIFACT_DIR}/kubeconfig.yaml" ]] || copy_guest_file "${ARTIFACT_PREFIX}.kubeconfig" "${ARTIFACT_DIR}/kubeconfig.yaml"
  [[ -f "${ARTIFACT_DIR}/istio-pods.txt" ]] || copy_guest_file "${ARTIFACT_PREFIX}.istio-pods" "${ARTIFACT_DIR}/istio-pods.txt"
  [[ -f "${ARTIFACT_DIR}/istioctl-version.txt" ]] || true
  [[ -f "${RUN_ROOT}/api-lb-version.json" ]] && cp "${RUN_ROOT}/api-lb-version.json" "${RUN_ROOT}/artifacts/api-lb-version.json"
  [[ -f "${RUN_ROOT}/istio-install.log" ]] && cp "${RUN_ROOT}/istio-install.log" "${RUN_ROOT}/artifacts/istio-install.log"
  [[ -f "${RUN_ROOT}/istio-namespace.log" ]] && cp "${RUN_ROOT}/istio-namespace.log" "${RUN_ROOT}/artifacts/istio-namespace.log"
  [[ -f "${RUN_ROOT}/istio-rollout.log" ]] && cp "${RUN_ROOT}/istio-rollout.log" "${RUN_ROOT}/artifacts/istio-rollout.log"
  [[ -f "${RUN_ROOT}/istio-tolerations.log" ]] && cp "${RUN_ROOT}/istio-tolerations.log" "${RUN_ROOT}/artifacts/istio-tolerations.log"
  [[ -f "${RUN_ROOT}/istio-resources.log" ]] && cp "${RUN_ROOT}/istio-resources.log" "${RUN_ROOT}/artifacts/istio-resources.log"
  if [[ "${CONTROL_PLANE_RUNTIME}" == "nsjail" ]]; then
    for i in $(seq 0 "$((CONTROL_PLANE_COUNT - 1))"); do
      local name
      name="$(node_name "${i}")"
      [[ -f "${RUN_ROOT}/nsjail-migrate-${name}.log" ]] && cp "${RUN_ROOT}/nsjail-migrate-${name}.log" "${RUN_ROOT}/artifacts/nsjail-migrate-${name}.log"
      [[ -f "${RUN_ROOT}/nsjail-verify-${name}.log" ]] && cp "${RUN_ROOT}/nsjail-verify-${name}.log" "${RUN_ROOT}/artifacts/nsjail-verify-${name}.log"
    done
  fi
  collect_diagnostics
  cat >"${RUN_ROOT}/artifacts/receipt.json" <<EOF
{"cluster":"kubeadm-firecracker-ha","status":"succeeded","apiLbEndpoint":"${API_LB_ENDPOINT}","primaryControlPlaneIP":"${PRIMARY_CONTROL_PLANE_IP}","cidr":"${CIDR}","controlPlaneCount":${CONTROL_PLANE_COUNT},"workerCount":${WORKER_COUNT},"nodeCount":${NODE_COUNT},"kubernetesMinor":"${KUBERNETES_MINOR}","kubernetesVersion":"${KUBERNETES_VERSION:-latest-${KUBERNETES_MINOR}}","kubernetesPackageSource":"$( if [[ -n "${PACKAGE_REPO_ROOT}" && "${PACKAGE_REPO_MODE}" == "strict" ]]; then printf '%s' 'k8s-release-repo'; elif [[ -n "${PACKAGE_REPO_ROOT}" ]]; then printf '%s' 'k8s-release-repo+pkgs.k8s.io'; else printf '%s' 'pkgs.k8s.io'; fi )","podCIDR":"${POD_CIDR}","serviceCIDR":"${SERVICE_CIDR}","networkPlugin":"${NETWORK_PLUGIN}","controlPlaneRuntime":"${CONTROL_PLANE_RUNTIME}","guestSelinuxMode":"${GUEST_SELINUX_MODE}","ciliumVersion":"${CILIUM_VERSION}","flannelVersion":"${FLANNEL_VERSION:-latest}","flannelManifestURL":"${FLANNEL_MANIFEST_URL}","istioEnabled":$( [[ "${INSTALL_ISTIO}" == "1" ]] && printf '%s' 'true' || printf '%s' 'false' ),"istioProfile":"${ISTIO_PROFILE}","istioVersion":"${ISTIO_VERSION}"}
EOF
}

cleanup_run() {
  set +e
  docker rm -f "${API_LB_CONTAINER_NAME}" >/dev/null 2>&1 || true
  for pid_file in "${RUN_ROOT}"/nodes/*/pid; do
    [[ -f "${pid_file}" ]] || continue
    kill "$(cat "${pid_file}")" 2>/dev/null || true
  done
  pkill -f "${RUN_ROOT}/nodes/.*/fc.sock" >/dev/null 2>&1 || true
  sleep 1
  for pid_file in "${RUN_ROOT}"/nodes/*/pid; do
    [[ -f "${pid_file}" ]] || continue
    kill -9 "$(cat "${pid_file}")" 2>/dev/null || true
  done
  pkill -9 -f "${RUN_ROOT}/nodes/.*/fc.sock" >/dev/null 2>&1 || true
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    ip link del "$(node_tap "${i}")" 2>/dev/null || true
  done
  iptables -D FORWARD -i "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "${BRIDGE_NAME}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "${CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE 2>/dev/null || true
  ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
  ip link del "${BRIDGE_NAME}" type bridge 2>/dev/null || true
  rm -rf "${RUN_ROOT}"
  set -e
}

status_cluster() {
  if [[ -f "${RUN_ROOT}/artifacts/receipt.json" ]]; then
    cat "${RUN_ROOT}/artifacts/receipt.json"
    echo
    [[ -f "${RUN_ROOT}/artifacts/nodes.txt" ]] && cat "${RUN_ROOT}/artifacts/nodes.txt"
    exit 0
  fi
  echo "no cluster artifacts at ${RUN_ROOT}" >&2
  exit 1
}

on_exit() {
  local status="$?"
  trap - EXIT
  if [[ "${MODE}" == "apply" && "${APPLY_ACTIVE}" == "1" && "${status}" -ne 0 ]]; then
    echo "apply failed; collecting diagnostics under ${RUN_ROOT}/artifacts" >&2
    collect_diagnostics || true
  fi
  exit "${status}"
}

trap on_exit EXIT

apply_cluster() {
  validate_config
  require_cmd awk
  require_cmd chroot
  require_cmd curl
  require_cmd dpkg-deb
  require_cmd docker
  require_cmd e2fsck
  require_cmd grep
  require_cmd ip
  require_cmd iptables
  require_cmd mkfs.ext4
  require_cmd mount
  require_cmd resize2fs
  require_cmd sha256sum
  require_cmd sort
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd truncate
  require_cmd umount
  require_cmd unsquashfs
  [[ -x "${FIRECRACKER_BIN}" ]] || {
    echo "missing Firecracker binary at ${FIRECRACKER_BIN}" >&2
    exit 2
  }

  APPLY_ACTIVE="1"
  mkdir -p "${RUN_ROOT}" "${CACHE_ROOT}"
  cleanup_run
  mkdir -p "${ARTIFACT_DIR}"
  prepare_host_kubectl
  ensure_guest_ssh_key
  download_firecracker_assets || exit 1
  ensure_base_rootfs || exit 1
  prepare_base_image || exit 1
  setup_bridge

  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    boot_node "${i}"
  done
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    wait_for_ssh "$(node_ip "${i}")"
  done
  for i in $(seq 0 "$((NODE_COUNT - 1))"); do
    prepare_node_runtime "${i}"
  done

  setup_api_lb
  init_primary_control_plane
  join_additional_control_planes
  join_workers
  wait_for_cluster
  migrate_control_planes_to_nsjail
  rebalance_coredns
  wait_for_cluster
  verify_cluster_version
  capture_etcd_members
  run_smoke
  install_istio_addon
  verify_api_lb
  collect_artifacts
  APPLY_ACTIVE="0"

  cat "${RUN_ROOT}/artifacts/receipt.json"
  echo
  cat "${RUN_ROOT}/artifacts/nodes.txt"
  echo
  cat "${RUN_ROOT}/artifacts/etcd-members.txt"
  echo
  cat "${RUN_ROOT}/artifacts/smoke-job.log"
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
