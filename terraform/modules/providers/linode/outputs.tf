# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Instance public IPv4 address (empty string when ip_stack = 'ipv6')."
  # linode_instance.ipv4 is a set of all assigned IPv4 addresses; the first is the public one.
  value = var.ip_stack != "ipv6" ? tolist(linode_instance.main.ipv4)[0] : ""
}

output "public_ipv6" {
  description = "Instance public IPv6 address (empty string when ip_stack = 'ipv4'). Linode SLAAC prefix stripped."
  # Linode exposes the SLAAC address as "addr/128"; split to get the bare address.
  value = var.ip_stack != "ipv4" ? split("/", linode_instance.main.ipv6)[0] : ""
}

output "ssh_user" {
  description = "SSH login user. Linode Debian instances boot with root SSH key access."
  value       = "root"
}

output "instance_id" {
  description = "Linode instance ID for lifecycle operations."
  value       = linode_instance.main.id
}
