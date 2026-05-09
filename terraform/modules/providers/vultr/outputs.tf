# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "VPS public IP address."
  value       = vultr_instance.main.main_ip
}

output "ssh_user" {
  description = "SSH login user. Vultr Debian instances boot as root."
  value       = "root"
}

output "instance_id" {
  description = "Vultr instance ID for lifecycle operations."
  value       = vultr_instance.main.id
}
