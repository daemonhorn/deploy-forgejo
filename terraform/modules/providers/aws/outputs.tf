# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Instance public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? aws_instance.main.public_ip : ""
}

output "public_ipv6" {
  description = "Instance public IPv6 address (empty string when ip_stack = 'ipv4')."
  value       = var.ip_stack != "ipv4" ? try(aws_instance.main.ipv6_addresses[0], "") : ""
}

output "ssh_user" {
  description = "SSH login user. user_data bootstraps root access so provision.sh is provider-agnostic."
  value       = "root"
}

output "instance_id" {
  description = "EC2 instance ID for lifecycle operations."
  value       = aws_instance.main.id
}
