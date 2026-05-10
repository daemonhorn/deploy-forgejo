# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Instance public IP address."
  value       = azurerm_public_ip.main.ip_address
}

output "ssh_user" {
  description = "SSH login user. custom_data bootstraps root access so provision.sh is provider-agnostic."
  value       = "root"
}

output "instance_id" {
  description = "Azure VM resource ID for lifecycle operations."
  value       = azurerm_linux_virtual_machine.main.id
}
