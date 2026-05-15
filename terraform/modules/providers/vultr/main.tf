terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
  }
}

# Debian 12 (Bookworm) x64 — minimal footprint, long support window.
# To find the current OS ID: vultr.com/api/#tag/os or `vultr-cli os list`
locals {
  # Debian 12 x64 OS ID on Vultr (verify with API if this changes)
  debian12_os_id = 2136
}

resource "vultr_ssh_key" "admin" {
  name    = "${var.hostname}-admin"
  ssh_key = var.ssh_public_key
}

resource "vultr_firewall_group" "main" {
  description = "${var.hostname} firewall"
}

# IPv4 ingress rules — omitted in ipv6-only mode so all IPv4 traffic is dropped.
resource "vultr_firewall_rule" "inbound_v4" {
  for_each = var.ip_stack != "ipv6" ? toset([for p in var.firewall_ports : tostring(p)]) : toset([])

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = each.value
  notes             = "port ${each.value}"
}

# IPv6 ingress rules — added in dual and ipv6-only modes.
resource "vultr_firewall_rule" "inbound_v6" {
  for_each = var.ip_stack != "ipv4" ? toset([for p in var.firewall_ports : tostring(p)]) : toset([])

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = each.value
  notes             = "port ${each.value} IPv6"
}

resource "vultr_instance" "main" {
  region            = var.region
  plan              = var.plan
  os_id             = local.debian12_os_id
  hostname          = var.hostname
  label             = var.hostname
  ssh_key_ids       = [vultr_ssh_key.admin.id]
  firewall_group_id = vultr_firewall_group.main.id

  # Vultr always assigns an IPv4 address; enable_ipv6 adds a second IPv6 address.
  # In ipv6-only mode the IPv4 address still exists at the network layer but
  # firewall rules block all IPv4 inbound, so only IPv6 is reachable.
  enable_ipv6     = var.ip_stack != "ipv4"
  backups         = "disabled"
  ddos_protection = false
}
