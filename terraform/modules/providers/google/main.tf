terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

locals {
  # GCP uses zones for instances (e.g. "us-east1-b") but regional resources (static IPs,
  # subnets) need the region ("us-east1"). Strip the last dash-segment from the zone.
  region = join("-", slice(split("-", var.region), 0, length(split("-", var.region)) - 1))

  # Network tag applied to the instance; all firewall rules target this tag.
  instance_tag = "${var.hostname}-forgejo"

  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]

  # Ports within admin_only_ports that user CIDRs may also reach (excludes port 22).
  user_accessible_ports = [for p in var.admin_only_ports : p if !contains([22], p)]

  # GCP source_ranges accepts mixed IPv4 and IPv6 CIDRs in the same rule.
  # Filter by ip_stack so we don't add IPv4 rules in ipv6-only mode or vice versa.
  admin_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.allowed_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.allowed_cidrs : c if strcontains(c, ":")] : []
  )
  user_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.user_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.user_cidrs : c if strcontains(c, ":")] : []
  )

  # Source ranges for public rules based on ip_stack.
  public_source_ranges = concat(
    var.ip_stack != "ipv6" ? ["0.0.0.0/0"] : [],
    var.ip_stack != "ipv4" ? ["::/0"] : []
  )

  # Bootstrap script: GCP instances cannot be provisioned as root. We inject the SSH key
  # for an 'admin' user via metadata, then copy authorized_keys to root at first boot.
  # This mirrors the pattern used by the AWS and Azure provider modules.
  root_bootstrap = <<-EOT
    #!/bin/bash
    set -e
    for i in $(seq 1 60); do
      [ -f /home/admin/.ssh/authorized_keys ] && break
      sleep 1
    done
    [ -f /home/admin/.ssh/authorized_keys ] || { echo "ERROR: authorized_keys never appeared" >&2; exit 1; }
    mkdir -p /root/.ssh
    cp /home/admin/.ssh/authorized_keys /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart ssh
  EOT
}

# ── VPC and subnet ─────────────────────────────────────────────────────────────
# Always create a custom VPC: avoids relying on the default network's existence or
# pre-existing firewall rules, and allows full IPv6 subnet configuration.
resource "google_compute_network" "main" {
  name                    = "${var.hostname}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.hostname}-subnet"
  network       = google_compute_network.main.id
  region        = local.region
  ip_cidr_range = "10.0.1.0/24"

  # dual/ipv6 mode: enable external GUA IPv6. The subnet automatically receives a
  # /64 from Google's IPv6 range; instances with ipv6_access_config get an ephemeral
  # address from that range. ipv6_access_type is immutable — changing ip_stack on an
  # existing deployment requires destroy+apply.
  stack_type       = var.ip_stack != "ipv4" ? "IPV4_IPV6" : "IPV4_ONLY"
  ipv6_access_type = var.ip_stack != "ipv4" ? "EXTERNAL" : null
}

# ── Static external IPv4 address ───────────────────────────────────────────────
# A static IP keeps the TLS certificate valid across reboots.
resource "google_compute_address" "ipv4" {
  count        = var.ip_stack != "ipv6" ? 1 : 0
  name         = "${var.hostname}-ip"
  region       = local.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

# ── Firewall rules ─────────────────────────────────────────────────────────────
# GCP firewall rules target instances by network tag. All rules use source_ranges
# that accept mixed IPv4/IPv6 CIDRs — no need to split by address family per rule.

# World-open ingress for public ports (port 80 for ACME HTTP-01).
resource "google_compute_firewall" "public" {
  count   = length(local.public_ports) > 0 ? 1 : 0
  name    = "${var.hostname}-public"
  network = google_compute_network.main.name

  target_tags = [local.instance_tag]

  allow {
    protocol = "tcp"
    ports    = [for p in local.public_ports : tostring(p)]
  }

  source_ranges = local.public_source_ranges
}

# Admin-only ingress: SSH (22), Forgejo SSH (2222), HTTPS (443).
# Not created when allowed_cidrs is empty (fail-closed).
resource "google_compute_firewall" "admin" {
  count   = length(local.admin_cidrs) > 0 ? 1 : 0
  name    = "${var.hostname}-admin"
  network = google_compute_network.main.name

  target_tags = [local.instance_tag]

  allow {
    protocol = "tcp"
    ports    = [for p in var.admin_only_ports : tostring(p)]
  }

  source_ranges = local.admin_cidrs
}

# User-accessible ingress: ports 2222 and 443 only (port 22 excluded).
# Not created when user_cidrs is empty (fail-closed).
resource "google_compute_firewall" "user" {
  count   = length(local.user_cidrs) > 0 ? 1 : 0
  name    = "${var.hostname}-user"
  network = google_compute_network.main.name

  target_tags = [local.instance_tag]

  allow {
    protocol = "tcp"
    ports    = [for p in local.user_accessible_ports : tostring(p)]
  }

  source_ranges = local.user_cidrs
}

# ── Instance ──────────────────────────────────────────────────────────────────
resource "google_compute_instance" "main" {
  name         = var.hostname
  machine_type = var.plan
  zone         = var.region

  # The instance_tag ties firewall rules to this specific instance.
  tags = [local.instance_tag]

  boot_disk {
    initialize_params {
      # Debian 12 (Bookworm) from the official Debian Cloud publisher.
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id

    # External IPv4 — omitted in ipv6-only mode (no public IPv4 assigned).
    dynamic "access_config" {
      for_each = var.ip_stack != "ipv6" ? [1] : []
      content {
        nat_ip       = google_compute_address.ipv4[0].address
        network_tier = "PREMIUM"
      }
    }

    # External ephemeral IPv6 — added in dual and ipv6-only modes.
    # Address is auto-assigned from the subnet's /64 prefix; stable for instance lifetime.
    dynamic "ipv6_access_config" {
      for_each = var.ip_stack != "ipv4" ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  metadata = {
    # SSH key injection: GCP guest agent creates the 'admin' user with this key.
    # The startup-script then copies it to root so provision.sh can SSH as root
    # consistently across all providers.
    ssh-keys       = "admin:${var.ssh_public_key}"
    enable-oslogin = "FALSE"
    startup-script = local.root_bootstrap
  }

  # Required: allow Terraform to stop the instance when modifying certain attributes.
  allow_stopping_for_update = true
}
