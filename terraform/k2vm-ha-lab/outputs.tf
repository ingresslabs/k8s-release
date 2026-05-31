output "manifest_path" {
  value       = local_sensitive_file.manifest.filename
  description = "Rendered Terraform lab manifest path."
}

output "output_dir" {
  value       = local.effective_output_dir
  description = "Local artifact output directory used by k2vm."
}

output "target_host" {
  value       = local.effective_host
  description = "Remote host used for the lab."
}
