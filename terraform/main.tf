terraform {
  required_version = ">= 1.5"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
  }

  # TODO: migrate to an encrypted remote backend (S3/GCS with SSE) before team use.
  # The local state file (.terraform.tfstate) is gitignored; chmod 600 it manually.
  backend "local" {}
}

provider "vultr" {
  api_key     = var.vultr_api_key
  rate_limit  = 100
  retry_limit = 3
}

module "infra" {
  source = "./modules/providers/${var.provider_name}"

  ssh_public_key = var.admin_ssh_public_key
  region         = var.region
  plan           = var.plan
  hostname       = var.hostname
  firewall_ports = var.firewall_ports
}
