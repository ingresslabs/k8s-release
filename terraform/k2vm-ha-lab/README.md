# Terraform K2VM HA Lab

This is an alternate operator interface for the Firecracker lab.
The main script-driven flow stays intact in `scripts/k2vm.py`.

Use this wrapper when you want cluster lifecycle commands to be:

```bash
terraform apply
terraform destroy
```

## Host Input

Do not hard-code the remote host in Terraform files.

- Preferred: keep `K8S_RELEASE_PROOF_HOST=root@YOUR_HOST` in the repo-local
  `../../.env` file.
- Optional: set `target_host` in `terraform.tfvars`.

## Commands

```bash
cd terraform/k2vm-ha-lab
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
terraform destroy
```

## What It Does

- renders a lab manifest locally
- stages GitHub Actions package artifacts into a local DEB repo
- uploads its own vendored kubeadm Firecracker engine to the remote host
- runs that engine directly on `terraform apply`
- runs that engine directly on `terraform destroy`

## Defaults

The module defaults to the SELinux-capable HA lab profile:

- 3 control planes
- 1 worker
- Flannel
- Istio enabled
- Ubuntu generic kernel + initrd + modules tar
- SELinux enforcing kernel parameters
