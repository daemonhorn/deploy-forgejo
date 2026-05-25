terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

locals {
  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]

  # Ports within admin_only_ports that user CIDRs may also reach (excludes port 22).
  user_accessible_ports = [for p in var.admin_only_ports : p if !contains([22], p)]

  # ip_stack-aware admin CIDRs: filter by address family to avoid adding IPv4 rules
  # in ipv6-only mode or IPv6 rules in ipv4-only mode. Mixed IPv4+IPv6 in ipv4 mode
  # source_addresses list is not an issue for DO firewall, but we stay consistent
  # with the pattern used in the Google module.
  admin_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.allowed_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.allowed_cidrs : c if strcontains(c, ":")] : []
  )

  user_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.user_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.user_cidrs : c if strcontains(c, ":")] : []
  )

  # Source ranges for world-open ports, filtered by ip_stack.
  public_source_ranges = concat(
    var.ip_stack != "ipv6" ? ["0.0.0.0/0"] : [],
    var.ip_stack != "ipv4" ? ["::/0"] : []
  )
}

resource "digitalocean_ssh_key" "admin" {
  name       = "${var.hostname}-admin"
  public_key = var.ssh_public_key
}

resource "digitalocean_droplet" "main" {
  image    = "debian-12-x64"
  name     = var.hostname
  region   = var.region
  size     = var.plan
  ssh_keys = [digitalocean_ssh_key.admin.fingerprint]

  # DigitalOcean always assigns an IPv4 address. ipv6 = true adds a /128 SLAAC IPv6 address.
  # In ipv6-only mode the IPv4 address still exists but the firewall blocks all IPv4 inbound.
  ipv6 = var.ip_stack != "ipv4"
}

resource "digitalocean_firewall" "main" {
  name        = "${var.hostname}-fw"
  droplet_ids = [digitalocean_droplet.main.id]

  # World-open ingress for public ports (e.g. port 80 for ACME HTTP-01).
  dynamic "inbound_rule" {
    for_each = { for p in local.public_ports : tostring(p) => p }
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.public_source_ranges
    }
  }

  # Admin-only ingress: 22, 2222, 443. Omitted when allowed_cidrs is empty (fail-closed).
  dynamic "inbound_rule" {
    for_each = length(local.admin_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.admin_cidrs
    }
  }

  # User-accessible ingress: 2222 and 443. Omitted when user_cidrs is empty (fail-closed).
  dynamic "inbound_rule" {
    for_each = length(local.user_cidrs) > 0 ? { for p in local.user_accessible_ports : tostring(p) => p } : {}
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.user_cidrs
    }
  }

  # Allow all outbound — required; DigitalOcean Cloud Firewall blocks all egress by default.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
