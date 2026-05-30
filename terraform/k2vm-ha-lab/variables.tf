variable "name" {
  type        = string
  default     = "selinux-istio-argocd-lab"
  description = "Cluster name used in the rendered k2vm spec."
}

variable "target_host" {
  type        = string
  default     = ""
  description = "Remote lab host. If empty, the wrapper reads K8S_RELEASE_PROOF_HOST from ../../.env."
}

variable "target_user" {
  type        = string
  default     = ""
  description = "Remote SSH user. Leave empty to use the user from target_host or root."
}

variable "remote_workdir" {
  type        = string
  default     = ""
  description = "Remote working directory for staged k2vm assets."
}

variable "output_dir" {
  type        = string
  default     = ""
  description = "Local artifact directory. Defaults under this Terraform module."
}

variable "github_repo" {
  type        = string
  default     = "ingresslabs/k8s-release"
  description = "GitHub repository that owns the package artifact run."
}

variable "github_run_id" {
  type        = number
  default     = 26680027183
  description = "GitHub Actions run id that produced the package artifacts."
}

variable "artifact_components" {
  type        = list(string)
  default     = ["kubelet", "kubectl", "kube-apiserver", "kube-controller-manager", "kube-scheduler", "kube-proxy", "etcd", "flannel", "istio"]
  description = "Package artifact components to stage for the lab."
}

variable "package_repository_mode" {
  type        = string
  default     = "hybrid"
  description = "k2vm package repository mode."
}

variable "enable_istio" {
  type        = bool
  default     = true
  description = "Enable Istio installation during apply."
}

variable "istio_profile" {
  type        = string
  default     = "minimal"
  description = "Istio profile to install."
}

variable "subnet_prefix" {
  type        = string
  default     = "198.19.2"
  description = "Subnet prefix for the Firecracker lab."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane nodes."
}

variable "worker_count" {
  type        = number
  default     = 1
  description = "Number of worker nodes."
}

variable "network_plugin" {
  type        = string
  default     = "flannel"
  description = "Cluster network plugin."
}

variable "kubernetes_version" {
  type        = string
  default     = "v1.36.1"
  description = "Kubernetes version to install."
}

variable "firecracker_binary" {
  type        = string
  default     = "/usr/local/bin/firecracker"
  description = "Firecracker binary path on the remote host."
}

variable "bridge_name" {
  type        = string
  default     = "k2vmslx2"
  description = "Bridge name on the remote host."
}

variable "tap_prefix" {
  type        = string
  default     = "k2vmslx2"
  description = "Tap device prefix on the remote host."
}

variable "kernel_source" {
  type        = string
  default     = "provided"
  description = "k2vm kernel source mode."
}

variable "kernel_path" {
  type        = string
  default     = "/opt/firecracker-sandbox-lab/vmlinux-5.15.0-184-generic"
  description = "Kernel path on the remote host."
}

variable "initrd_path" {
  type        = string
  default     = "/opt/firecracker-sandbox-lab/initrd-5.15.0-184-generic.img"
  description = "Initrd path on the remote host."
}

variable "kernel_modules_tar_path" {
  type        = string
  default     = "/opt/firecracker-sandbox-lab/modules-5.15.0-184-generic.tar.gz"
  description = "Kernel modules tarball path on the remote host."
}

variable "base_rootfs_path" {
  type        = string
  default     = "/opt/firecracker-sandbox-lab/rootfs-selinux.ext4"
  description = "Prepared SELinux-capable base rootfs on the remote host."
}

variable "kernel_params" {
  type        = list(string)
  default     = ["apparmor=0", "security=selinux", "selinux=1", "enforcing=1", "audit=1"]
  description = "Additional kernel parameters for the lab guests."
}

variable "vcpu_count" {
  type        = number
  default     = 2
  description = "vCPU count per guest."
}

variable "run_root" {
  type        = string
  default     = "/var/lib/k2vm-kubeadm-ha-selinux"
  description = "Remote run root."
}

variable "cache_root" {
  type        = string
  default     = "/var/cache/k2vm-kubeadm-ha-selinux"
  description = "Remote cache root."
}

variable "python_bin" {
  type        = string
  default     = "python3"
  description = "Python interpreter used to run k2vm.py locally."
}

variable "log_level" {
  type        = string
  default     = "INFO"
  description = "Client log level for the rendered spec."
}

variable "redeploy_token" {
  type        = string
  default     = ""
  description = "Change this value to force Terraform to re-run apply."
}

