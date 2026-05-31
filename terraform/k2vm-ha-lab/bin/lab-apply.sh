#!/usr/bin/env bash
set -euo pipefail

manifest_path="${1:?usage: lab-apply.sh <manifest.json>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine_path="${script_dir}/k2vm-kubeadm-engine.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

for cmd in jq gh ssh scp unzip find mktemp curl; do
  require_cmd "${cmd}"
done

ssh_opts=(
  -o BatchMode=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=12
)

jq_get() {
  jq -r "$1" "${manifest_path}"
}

manifest_dir="$(cd -- "$(dirname -- "${manifest_path}")" && pwd)"
name="$(jq_get '.name')"
target_user="$(jq_get '.target.user')"
target_host="$(jq_get '.target.host')"
target="${target_user}@${target_host}"
remote_workdir="$(jq_get '.target.workdir')"
remote_bundle="${remote_workdir}/bundle"
run_root="$(jq_get '.paths.run_root')"
cache_root="$(jq_get '.paths.cache_root')"
output_dir="$(jq_get '.paths.local_output_dir')"
mkdir -p "${output_dir}"

repo="$(jq_get '.release.github_repo')"
run_id="$(jq_get '.release.github_run.run_id')"
github_meta_path="${output_dir}/release-artifacts-meta.json"
stage_root="${manifest_dir}/.stage/${name}"
raw_dir="${stage_root}/raw"
package_repo_dir="${stage_root}/package-repositories"
mkdir -p "${raw_dir}" "${package_repo_dir}/debian" "${package_repo_dir}/tools"
rm -rf "${stage_root:?}/raw" "${stage_root:?}/package-repositories"
mkdir -p "${raw_dir}" "${package_repo_dir}/debian" "${package_repo_dir}/tools"

artifacts_json="$(gh api "repos/${repo}/actions/runs/${run_id}/artifacts" --paginate)"
printf '%s\n' "${artifacts_json}" > "${github_meta_path}"

kubelet_artifact_name="$(
  printf '%s' "${artifacts_json}" |
    jq -r '.artifacts[] | select(.name | endswith("-kubelet-packages")) | .name' |
    head -n1
)"
if [[ -z "${kubelet_artifact_name}" ]]; then
  echo "failed to locate kubelet artifact name for run ${run_id}" >&2
  exit 1
fi

if [[ "${kubelet_artifact_name}" =~ ^(v[^-]+)-(v[^-]+)-(v[^-]+)-(v[^-]+)(-([^-]+))?-kubelet-packages$ ]]; then
  kubernetes_version="${BASH_REMATCH[1]}"
  kubernetes_minor="${kubernetes_version%.*}"
  etcd_version="${BASH_REMATCH[2]}"
  flannel_version="${BASH_REMATCH[3]}"
  calico_version="${BASH_REMATCH[4]}"
  istio_version="${BASH_REMATCH[6]:-}"
else
  echo "failed to parse artifact label from ${kubelet_artifact_name}" >&2
  exit 1
fi

components=()
while IFS= read -r component; do
  components+=("${component}")
done < <(jq -r '.release.package_repository.artifact_components[]' "${manifest_path}")
for component in "${components[@]}"; do
  suffix="-${component}-packages"
  artifact_id="$(
    printf '%s' "${artifacts_json}" |
      jq -r --arg suffix "${suffix}" '.artifacts[] | select(.name | endswith($suffix)) | .id' |
      head -n1
  )"
  artifact_name="$(
    printf '%s' "${artifacts_json}" |
      jq -r --arg suffix "${suffix}" '.artifacts[] | select(.name | endswith($suffix)) | .name' |
      head -n1
  )"
  if [[ -z "${artifact_id}" || -z "${artifact_name}" ]]; then
    echo "missing artifact for component ${component} in run ${run_id}" >&2
    exit 1
  fi

  zip_path="${raw_dir}/${artifact_name}.zip"
  unpack_dir="${raw_dir}/${component}"
  mkdir -p "${unpack_dir}"
  gh api "repos/${repo}/actions/artifacts/${artifact_id}/zip" > "${zip_path}"
  unzip -qo "${zip_path}" -d "${unpack_dir}"
  find "${unpack_dir}" -type f -name '*.deb' -exec cp {} "${package_repo_dir}/debian/" \;
  if [[ "${component}" == "istio" ]]; then
    istioctl_path="$(find "${unpack_dir}" -type f -name 'istioctl' | head -n1 || true)"
    if [[ -n "${istioctl_path}" ]]; then
      cp "${istioctl_path}" "${package_repo_dir}/tools/istioctl"
      chmod +x "${package_repo_dir}/tools/istioctl"
    fi
  fi
  rm -rf "${unpack_dir}" "${zip_path}"
done

if ! find "${package_repo_dir}/debian" -maxdepth 1 -type f -name 'kubeadm_*.deb' | grep -q .; then
  kubeadm_version="${kubernetes_version#v}-1.1"
  kubeadm_url="https://pkgs.k8s.io/core:/stable:/${kubernetes_minor}/deb/amd64/kubeadm_${kubeadm_version}_amd64.deb"
  curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 "${kubeadm_url}" -o "${package_repo_dir}/debian/$(basename "${kubeadm_url}")"
fi

ssh "${ssh_opts[@]}" "${target}" "rm -rf $(printf '%q' "${remote_workdir}") && mkdir -p $(printf '%q' "${remote_bundle}/release-inputs")"
scp "${ssh_opts[@]}" "${engine_path}" "${target}:${remote_bundle}/"
scp "${ssh_opts[@]}" -r "${package_repo_dir}" "${target}:${remote_bundle}/release-inputs/package-repositories"
ssh "${ssh_opts[@]}" "${target}" "cd $(printf '%q' "${remote_bundle}/release-inputs/package-repositories/debian") && dpkg-scanpackages . /dev/null > Packages && gzip -9c Packages > Packages.gz"

fetch_artifacts() {
  scp "${ssh_opts[@]}" -r "${target}:${run_root}/artifacts" "${output_dir}/" >/dev/null 2>&1 || true
}
trap fetch_artifacts EXIT

subnet_prefix="$(jq_get '.cluster.subnet_prefix')"
control_plane_count="$(jq_get '.cluster.control_plane_count')"
worker_count="$(jq_get '.cluster.worker_count')"
network_plugin="$(jq_get '.cluster.network_plugin')"
control_plane_runtime="$(jq_get '.cluster.control_plane_runtime // "static-pods"')"
firecracker_binary="$(jq_get '.firecracker.binary')"
bridge_name="$(jq_get '.firecracker.bridge_name')"
tap_prefix="$(jq_get '.firecracker.tap_prefix')"
kernel_source="$(jq_get '.firecracker.kernel_source')"
kernel_path="$(jq_get '.firecracker.kernel_path')"
initrd_path="$(jq_get '.firecracker.initrd_path')"
kernel_modules_tar_path="$(jq_get '.firecracker.kernel_modules_tar_path')"
base_rootfs_path="$(jq_get '.firecracker.base_rootfs_path')"
vcpu_count="$(jq_get '.firecracker.vcpu_count')"
kernel_params="$(jq -r '.firecracker.kernel_params | join(" ")' "${manifest_path}")"
guest_selinux_mode="$(jq_get '.guest.selinux_mode // "enforcing"')"
istio_enabled="$(jq_get '.addons.istio.enabled')"
istio_profile="$(jq_get '.addons.istio.profile')"
pod_cidr="$(jq -r '.cluster.pod_cidr // "10.244.0.0/16"' "${manifest_path}")"
service_cidr="$(jq -r '.cluster.service_cidr // "10.96.0.0/12"' "${manifest_path}")"
package_repo_mode="$(jq_get '.release.package_repository.mode')"
api_lb_ip="${subnet_prefix}.5"
api_lb_port="6443"

env_args=(
  "RUN_ROOT=${run_root}"
  "CACHE_ROOT=${cache_root}"
  "FIRECRACKER_BIN=${firecracker_binary}"
  "BRIDGE_NAME=${bridge_name}"
  "TAP_PREFIX=${tap_prefix}"
  "SUBNET_PREFIX=${subnet_prefix}"
  "KERNEL_SOURCE=${kernel_source}"
  "CONTROL_PLANE_COUNT=${control_plane_count}"
  "WORKER_COUNT=${worker_count}"
  "KUBERNETES_MINOR=${kubernetes_minor}"
  "POD_CIDR=${pod_cidr}"
  "SERVICE_CIDR=${service_cidr}"
  "NETWORK_PLUGIN=${network_plugin}"
  "CONTROL_PLANE_RUNTIME=${control_plane_runtime}"
  "GUEST_SELINUX_MODE=${guest_selinux_mode}"
  "API_LB_IP=${api_lb_ip}"
  "API_LB_PORT=${api_lb_port}"
  "VCPU_COUNT=${vcpu_count}"
  "KUBERNETES_VERSION=${kubernetes_version}"
  "FLANNEL_VERSION=${flannel_version}"
  "PACKAGE_REPO_ROOT=${remote_bundle}/release-inputs/package-repositories"
  "PACKAGE_REPO_MODE=${package_repo_mode}"
  "PACKAGE_REPO_LAYOUT=component_packages"
  "PACKAGE_REPO_TRUSTED=1"
  "KERNEL_PATH=${kernel_path}"
  "INITRD_PATH=${initrd_path}"
  "KERNEL_MODULES_TAR_PATH=${kernel_modules_tar_path}"
  "BASE_ROOTFS_PATH=${base_rootfs_path}"
  "K2VM_ENGINE_PATH=${remote_bundle}/$(basename "${engine_path}")"
)
if [[ -n "${kernel_params}" ]]; then
  env_args+=("KERNEL_BOOT_ARGS_EXTRA=${kernel_params}")
fi
if [[ "${istio_enabled}" == "true" ]]; then
  env_args+=(
    "INSTALL_ISTIO=1"
    "ISTIOCTL_BIN=${remote_bundle}/release-inputs/package-repositories/tools/istioctl"
    "ISTIO_PROFILE=${istio_profile}"
  )
  if [[ -n "${istio_version}" ]]; then
    env_args+=("ISTIO_VERSION=${istio_version}")
  fi
fi

printf -v remote_env '%q ' "${env_args[@]}"
ssh "${ssh_opts[@]}" "${target}" "${remote_env}bash $(printf '%q' "${remote_bundle}/$(basename "${engine_path}")") apply"
trap - EXIT
fetch_artifacts
