#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?usage: lab-destroy.sh <manifest.json>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine_path="${script_dir}/k2vm-kubeadm-engine.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

for cmd in jq ssh scp; do
  require_cmd "${cmd}"
done

jq_get() {
  jq -r "$1" "${manifest_path}"
}

target_user="$(jq_get '.target.user')"
target_host="$(jq_get '.target.host')"
target="${target_user}@${target_host}"
remote_workdir="$(jq_get '.target.workdir')"
remote_bundle="${remote_workdir}/bundle"

ssh "${target}" "mkdir -p $(printf '%q' "${remote_bundle}")"
scp "${engine_path}" "${target}:${remote_bundle}/"

subnet_prefix="$(jq_get '.cluster.subnet_prefix')"
kubernetes_version="$(jq_get '.cluster.kubernetes_version')"
kubernetes_minor="${kubernetes_version%.*}"
kernel_params="$(jq -r '.firecracker.kernel_params | join(" ")' "${manifest_path}")"
pod_cidr="$(jq -r '.cluster.pod_cidr // "10.244.0.0/16"' "${manifest_path}")"
service_cidr="$(jq -r '.cluster.service_cidr // "10.96.0.0/12"' "${manifest_path}")"

env_args=(
  "RUN_ROOT=$(jq_get '.paths.run_root')"
  "CACHE_ROOT=$(jq_get '.paths.cache_root')"
  "FIRECRACKER_BIN=$(jq_get '.firecracker.binary')"
  "BRIDGE_NAME=$(jq_get '.firecracker.bridge_name')"
  "TAP_PREFIX=$(jq_get '.firecracker.tap_prefix')"
  "SUBNET_PREFIX=${subnet_prefix}"
  "KERNEL_SOURCE=$(jq_get '.firecracker.kernel_source')"
  "CONTROL_PLANE_COUNT=$(jq_get '.cluster.control_plane_count')"
  "WORKER_COUNT=$(jq_get '.cluster.worker_count')"
  "KUBERNETES_MINOR=${kubernetes_minor}"
  "POD_CIDR=${pod_cidr}"
  "SERVICE_CIDR=${service_cidr}"
  "NETWORK_PLUGIN=$(jq_get '.cluster.network_plugin')"
  "API_LB_IP=${subnet_prefix}.5"
  "API_LB_PORT=6443"
  "VCPU_COUNT=$(jq_get '.firecracker.vcpu_count')"
  "KUBERNETES_VERSION=${kubernetes_version}"
  "FLANNEL_VERSION="
  "KERNEL_PATH=$(jq_get '.firecracker.kernel_path')"
  "INITRD_PATH=$(jq_get '.firecracker.initrd_path')"
  "KERNEL_MODULES_TAR_PATH=$(jq_get '.firecracker.kernel_modules_tar_path')"
  "BASE_ROOTFS_PATH=$(jq_get '.firecracker.base_rootfs_path')"
  "K2VM_ENGINE_PATH=${remote_bundle}/$(basename "${engine_path}")"
)
if [[ -n "${kernel_params}" ]]; then
  env_args+=("KERNEL_BOOT_ARGS_EXTRA=${kernel_params}")
fi

printf -v remote_env '%q ' "${env_args[@]}"
ssh "${target}" "${remote_env}bash $(printf '%q' "${remote_bundle}/$(basename "${engine_path}")") delete || true"
ssh "${target}" "rm -rf $(printf '%q' "${remote_workdir}")"
