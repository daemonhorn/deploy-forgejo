terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  # TODO: migrate to an encrypted remote backend (S3/GCS with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via DIGITALOCEAN_TOKEN env var (set by provision.sh from
# the digitalocean_personal_token file or Vault secret/forgejo/cloud).
provider "digitalocean" {}

module "infra" {
  source = "../modules/providers/digitalocean"

  ssh_public_key   = var.admin_ssh_public_key
  region           = var.region
  plan             = var.plan
  hostname         = var.hostname
  firewall_ports   = var.firewall_ports
  admin_only_ports = var.admin_only_ports
  allowed_cidrs    = var.allowed_cidrs
  user_cidrs       = var.user_cidrs
  ip_stack         = var.ip_stack
}
