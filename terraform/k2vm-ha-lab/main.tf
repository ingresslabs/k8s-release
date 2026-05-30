terraform {
  required_version = ">= 1.5.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

locals {
  repo_root   = abspath("${path.module}/../..")
  env_path    = "${local.repo_root}/.env"
  env_content = fileexists(local.env_path) ? file(local.env_path) : ""
  env_lines   = [for raw in split("\n", local.env_content) : trimspace(raw)]
  env_pairs = [
    for line in local.env_lines : regex("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
    if line != "" && !startswith(line, "#") && can(regex("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line))
  ]
  env_map = {
    for pair in local.env_pairs :
    pair[0] => trimsuffix(trimprefix(pair[1], "\""), "\"")
  }

  target_source       = var.target_host != "" ? var.target_host : lookup(local.env_map, "K8S_RELEASE_PROOF_HOST", "")
  target_source_parts = can(regex("^([^@]+)@(.+)$", local.target_source)) ? regex("^([^@]+)@(.+)$", local.target_source) : []
  effective_user      = var.target_user != "" ? var.target_user : (length(local.target_source_parts) == 2 ? local.target_source_parts[0] : "root")
  effective_host      = length(local.target_source_parts) == 2 ? local.target_source_parts[1] : local.target_source

  effective_output_dir = var.output_dir != "" ? abspath(var.output_dir) : abspath("${path.module}/output/${var.name}")
  effective_remote_dir = var.remote_workdir != "" ? var.remote_workdir : "/root/${var.name}"
  manifest_path        = "${path.module}/${var.name}.rendered.json"

  manifest = {
    schema_version = "k2vm.spec.v1"
    name           = var.name
    target = {
      host    = local.effective_host
      user    = local.effective_user
      workdir = local.effective_remote_dir
    }
    cluster = {
      distribution        = "kubeadm"
      subnet_prefix       = var.subnet_prefix
      control_plane_count = var.control_plane_count
      worker_count        = var.worker_count
      network_plugin      = var.network_plugin
      kubernetes_version  = var.kubernetes_version
    }
    firecracker = {
      binary                  = var.firecracker_binary
      bridge_name             = var.bridge_name
      tap_prefix              = var.tap_prefix
      kernel_source           = var.kernel_source
      kernel_path             = var.kernel_path
      initrd_path             = var.initrd_path
      kernel_modules_tar_path = var.kernel_modules_tar_path
      base_rootfs_path        = var.base_rootfs_path
      kernel_params           = var.kernel_params
      vcpu_count              = var.vcpu_count
    }
    paths = {
      run_root         = var.run_root
      cache_root       = var.cache_root
      local_output_dir = local.effective_output_dir
    }
    release = {
      enabled     = true
      github_repo = var.github_repo
      github_run = {
        repo   = var.github_repo
        run_id = var.github_run_id
      }
      package_repository = {
        source              = "github_run_artifact"
        artifact_layout     = "component_packages"
        artifact_components = var.artifact_components
        mode                = var.package_repository_mode
      }
    }
    addons = {
      istio = {
        enabled = var.enable_istio
        profile = var.istio_profile
      }
    }
    logging = {
      level  = var.log_level
      format = "text"
    }
  }
}

resource "local_sensitive_file" "manifest" {
  filename = local.manifest_path
  content  = jsonencode(local.manifest)
}

resource "null_resource" "lab" {
  triggers = {
    manifest_path     = local_sensitive_file.manifest.filename
    manifest_sha256   = sha256(nonsensitive(local_sensitive_file.manifest.content))
    apply_sh_sha256   = filesha256("${path.module}/bin/lab-apply.sh")
    destroy_sh_sha256 = filesha256("${path.module}/bin/lab-destroy.sh")
    engine_sh_sha256  = filesha256("${path.module}/bin/k2vm-kubeadm-engine.sh")
    redeploy_token    = var.redeploy_token
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "\"${path.module}/bin/lab-apply.sh\" \"${self.triggers.manifest_path}\""
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-lc"]
    command     = "\"${path.module}/bin/lab-destroy.sh\" \"${self.triggers.manifest_path}\""
  }

  lifecycle {
    precondition {
      condition     = local.effective_host != ""
      error_message = "Set target_host or define K8S_RELEASE_PROOF_HOST in the repo-local .env file."
    }
    precondition {
      condition     = fileexists("${path.module}/bin/k2vm-kubeadm-engine.sh")
      error_message = "Missing Terraform lab engine: terraform/k2vm-ha-lab/bin/k2vm-kubeadm-engine.sh"
    }
  }
}
