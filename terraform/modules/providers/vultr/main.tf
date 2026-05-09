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

resource "vultr_firewall_rule" "inbound" {
  for_each = toset([for p in var.firewall_ports : tostring(p)])

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = each.value
  notes             = "port ${each.value}"
}

resource "vultr_instance" "main" {
  region            = var.region
  plan              = var.plan
  os_id             = local.debian12_os_id
  hostname          = var.hostname
  label             = var.hostname
  ssh_key_ids       = [vultr_ssh_key.admin.id]
  firewall_group_id = vultr_firewall_group.main.id

  # Enable IPv6 and backups optionally; add variables to expose these if needed.
  enable_ipv6      = false
  backups          = "disabled"
  ddos_protection  = false
}
