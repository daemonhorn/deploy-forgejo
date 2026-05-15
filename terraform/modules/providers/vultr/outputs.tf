# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "VPS public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? vultr_instance.main.main_ip : ""
}

output "public_ipv6" {
  description = "VPS public IPv6 address (empty string when ip_stack = 'ipv4')."
  value       = var.ip_stack != "ipv4" ? vultr_instance.main.v6_main_ip : ""
}

output "ssh_user" {
  description = "SSH login user. Vultr Debian instances boot as root."
  value       = "root"
}

output "instance_id" {
  description = "Vultr instance ID for lifecycle operations."
  value       = vultr_instance.main.id
}
