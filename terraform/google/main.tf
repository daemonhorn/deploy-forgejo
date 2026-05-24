terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # TODO: migrate to an encrypted remote backend (GCS with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via GOOGLE_CREDENTIALS (JSON content) and GOOGLE_PROJECT
# env vars, both set by provision.sh from the google_credentials file.
provider "google" {}

module "infra" {
  source = "../modules/providers/google"

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
