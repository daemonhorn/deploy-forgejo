output "public_ipv4" {
  description = "VM public IP address."
  value       = module.infra.public_ipv4
}

output "ssh_user" {
  description = "SSH login user (always 'root' after custom_data bootstrap)."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "Azure VM resource ID."
  value       = module.infra.instance_id
}
