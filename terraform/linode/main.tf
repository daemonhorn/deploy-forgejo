terraform {
  required_version = ">= 1.5"

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

  # TODO: migrate to an encrypted remote backend (S3/GCS with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via LINODE_TOKEN env var (set by provision.sh from the linode_api_key file).
provider "linode" {}

provider "random" {}

module "infra" {
  source = "../modules/providers/linode"

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
