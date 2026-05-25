output "public_ipv4" {
  description = "Droplet public IPv4 address."
  value       = module.infra.public_ipv4
}

output "public_ipv6" {
  description = "Droplet public IPv6 address."
  value       = module.infra.public_ipv6
}

output "ssh_user" {
  description = "SSH user for provisioning."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "DigitalOcean droplet ID."
  value       = module.infra.instance_id
}
