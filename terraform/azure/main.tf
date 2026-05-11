terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # TODO: migrate to an encrypted remote backend (Azure Blob Storage with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_SUBSCRIPTION_ID,
# and ARM_TENANT_ID env vars (set by provision.sh from the azure_credentials file).
provider "azurerm" {
  features {}
}

module "infra" {
  source = "../modules/providers/azure"

  ssh_public_key = var.admin_ssh_public_key
  region         = var.region
  plan           = var.plan
  hostname       = var.hostname
  firewall_ports = var.firewall_ports
}
