output "public_ipv4" {
  description = "Instance public IP address."
  value       = module.infra.public_ipv4
}

output "ssh_user" {
  description = "SSH login user for the instance (provider-dependent)."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.infra.instance_id
}
