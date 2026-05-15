# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "VM public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? azurerm_public_ip.main.ip_address : ""
}

output "public_ipv6" {
  description = "VM public IPv6 address (empty string when ip_stack = 'ipv4')."
  value       = var.ip_stack != "ipv4" ? azurerm_public_ip.ipv6[0].ip_address : ""
}

output "ssh_user" {
  description = "SSH login user. custom_data bootstraps root access so provision.sh is provider-agnostic."
  value       = "root"
}

output "instance_id" {
  description = "Azure VM resource ID for lifecycle operations."
  value       = azurerm_linux_virtual_machine.main.id
}
