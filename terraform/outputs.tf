output "public_ipv4" {
  description = "VPS public IP address."
  value       = module.infra.public_ipv4
}

output "ssh_user" {
  description = "SSH login user for the VPS (provider-dependent)."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "Provider-native instance identifier."
  value       = module.infra.instance_id
}
