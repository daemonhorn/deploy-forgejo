output "public_ipv4" {
  description = "VPS public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = module.infra.public_ipv4
}

output "public_ipv6" {
  description = "VPS public IPv6 address (empty string when ip_stack = 'ipv4')."
  value       = module.infra.public_ipv6
}

output "ssh_user" {
  description = "SSH login user for the VPS (provider-dependent)."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "Provider-native instance identifier."
  value       = module.infra.instance_id
}
