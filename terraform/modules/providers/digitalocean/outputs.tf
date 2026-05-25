# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Droplet public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? digitalocean_droplet.main.ipv4_address : ""
}

output "public_ipv6" {
  description = "Droplet public IPv6 address (empty string when ip_stack = 'ipv4'). Bare address — no '/128' suffix."
  value       = var.ip_stack != "ipv4" ? digitalocean_droplet.main.ipv6_address : ""
}

output "ssh_user" {
  description = "SSH login user. DigitalOcean Debian droplets boot with root SSH key access."
  value       = "root"
}

output "instance_id" {
  description = "DigitalOcean droplet ID for lifecycle operations."
  value       = digitalocean_droplet.main.id
}
