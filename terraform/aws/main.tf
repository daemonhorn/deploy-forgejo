terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # TODO: migrate to an encrypted remote backend (S3 with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
# (set by provision.sh from the aws_access_key / aws_secret_access_key files).
provider "aws" {
  region = var.region
}

module "infra" {
  source = "../modules/providers/aws"

  ssh_public_key = var.admin_ssh_public_key
  region         = var.region
  plan           = var.plan
  hostname       = var.hostname
  firewall_ports = var.firewall_ports
}
