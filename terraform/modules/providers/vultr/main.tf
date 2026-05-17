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

  # Split allowed_cidrs into IPv4 (no colon) and IPv6 (contains colon).
  allowed_v4_cidrs = [for c in var.allowed_cidrs : c if !strcontains(c, ":")]
  allowed_v6_cidrs = [for c in var.allowed_cidrs : c if strcontains(c, ":")]

  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]

  # Cartesian product maps for admin-restricted rules: key = "port-cidr".
  admin_v4_rules = var.ip_stack != "ipv6" ? {
    for pair in setproduct(
      [for p in var.admin_only_ports : tostring(p)],
      local.allowed_v4_cidrs
    ) : "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  } : {}

  admin_v6_rules = var.ip_stack != "ipv4" ? {
    for pair in setproduct(
      [for p in var.admin_only_ports : tostring(p)],
      local.allowed_v6_cidrs
    ) : "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  } : {}
}

resource "vultr_ssh_key" "admin" {
  name    = "${var.hostname}-admin"
  ssh_key = var.ssh_public_key
}

resource "vultr_firewall_group" "main" {
  description = "${var.hostname} firewall"
}

# World-open IPv4 ingress for public ports (80, 443) — omitted in ipv6-only mode.
resource "vultr_firewall_rule" "public_v4" {
  for_each = var.ip_stack != "ipv6" ? toset([for p in local.public_ports : tostring(p)]) : toset([])

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = each.value
  notes             = "port ${each.value} public"
}

# World-open IPv6 ingress for public ports — added in dual and ipv6-only modes.
resource "vultr_firewall_rule" "public_v6" {
  for_each = var.ip_stack != "ipv4" ? toset([for p in local.public_ports : tostring(p)]) : toset([])

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = each.value
  notes             = "port ${each.value} public IPv6"
}

# Admin-only IPv4 ingress: one rule per (port, CIDR) pair.
resource "vultr_firewall_rule" "admin_v4" {
  for_each = local.admin_v4_rules

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", each.value.cidr)[0]
  subnet_size       = tonumber(split("/", each.value.cidr)[1])
  port              = each.value.port
  notes             = "port ${each.value.port} admin ${each.value.cidr}"
}

# Admin-only IPv6 ingress: one rule per (port, CIDR) pair.
resource "vultr_firewall_rule" "admin_v6" {
  for_each = local.admin_v6_rules

  firewall_group_id = vultr_firewall_group.main.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = split("/", each.value.cidr)[0]
  subnet_size       = tonumber(split("/", each.value.cidr)[1])
  port              = each.value.port
  notes             = "port ${each.value.port} admin ${each.value.cidr} IPv6"
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
