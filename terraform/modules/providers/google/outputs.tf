# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Instance public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? google_compute_address.ipv4[0].address : ""
}

output "public_ipv6" {
  description = "Instance public IPv6 address (empty string when ip_stack = 'ipv4'). Ephemeral from subnet /64."
  value       = var.ip_stack != "ipv4" ? google_compute_instance.main.network_interface[0].ipv6_access_config[0].external_ipv6 : ""
}

output "ssh_user" {
  description = "SSH login user. startup-script bootstraps root access so provision.sh is provider-agnostic."
  value       = "root"
}

output "instance_id" {
  description = "GCP instance ID for lifecycle operations."
  value       = google_compute_instance.main.id
}
