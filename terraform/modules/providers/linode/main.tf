terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

locals {
  # Split allowed_cidrs into IPv4 (no colon) and IPv6 (contains colon).
  allowed_v4_cidrs = [for c in var.allowed_cidrs : c if !strcontains(c, ":")]
  allowed_v6_cidrs = [for c in var.allowed_cidrs : c if strcontains(c, ":")]

  # Split user_cidrs by address family.
  user_v4_cidrs = [for c in var.user_cidrs : c if !strcontains(c, ":")]
  user_v6_cidrs = [for c in var.user_cidrs : c if strcontains(c, ":")]

  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]

  # Ports within admin_only_ports that user CIDRs may also reach (excludes port 22).
  user_accessible_ports = [for p in var.admin_only_ports : p if !contains([22], p)]
}

# Linode requires root_pass when image is set; generate a random one since SSH
# key auth is used exclusively and the root password is never needed.
resource "random_password" "root" {
  length           = 32
  special          = true
  # Linode's password validator rejects some special chars (< > : { } [ ]); restrict
  # to a safe subset. The password is never used — SSH key auth is the only login method.
  override_special = "!@#%^*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "linode_firewall" "main" {
  label           = "${var.hostname}-fw"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # World-open IPv4 ingress for public ports — omitted in ipv6-only mode.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv6" ? { for p in local.public_ports : tostring(p) => p } : {}
    content {
      label    = "public-v4-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv4     = ["0.0.0.0/0"]
    }
  }

  # World-open IPv6 ingress for public ports — added in dual and ipv6-only modes.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv4" ? { for p in local.public_ports : tostring(p) => p } : {}
    content {
      label    = "public-v6-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv6     = ["::/0"]
    }
  }

  # Admin-only IPv4 ingress: one rule per port with all allowed_v4_cidrs as sources.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv6" && length(local.allowed_v4_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    content {
      label    = "admin-v4-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv4     = local.allowed_v4_cidrs
    }
  }

  # Admin-only IPv6 ingress: one rule per port with all allowed_v6_cidrs as sources.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv4" && length(local.allowed_v6_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    content {
      label    = "admin-v6-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv6     = local.allowed_v6_cidrs
    }
  }

  # User-accessible IPv4 ingress: ports 2222 and 443, user CIDR list.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv6" && length(local.user_v4_cidrs) > 0 ? { for p in local.user_accessible_ports : tostring(p) => p } : {}
    content {
      label    = "user-v4-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv4     = local.user_v4_cidrs
    }
  }

  # User-accessible IPv6 ingress: ports 2222 and 443, user CIDR list.
  dynamic "inbound" {
    for_each = var.ip_stack != "ipv4" && length(local.user_v6_cidrs) > 0 ? { for p in local.user_accessible_ports : tostring(p) => p } : {}
    content {
      label    = "user-v6-${inbound.key}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.key
      ipv6     = local.user_v6_cidrs
    }
  }
}

resource "linode_instance" "main" {
  label           = var.hostname
  region          = var.region
  type            = var.plan
  image           = "linode/debian12"
  authorized_keys = [var.ssh_public_key]
  root_pass       = random_password.root.result

  # Linode always assigns both IPv4 and IPv6 (SLAAC /128) addresses regardless of ip_stack.
  # ip_stack controls firewall rules: ipv6 mode blocks all IPv4 inbound; ipv4 mode blocks IPv6.
}

# Attach the firewall to the instance as a separate resource (linode/linode v2+ API).
resource "linode_firewall_device" "main" {
  firewall_id = linode_firewall.main.id
  entity_id   = linode_instance.main.id
  entity_type = "linode"
}
