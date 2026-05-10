# Standard provider contract — all provider modules must accept these exact variables.

variable "ssh_public_key" {
  description = "Ed25519 public key material to upload for admin VPS access."
  type        = string
}

variable "region" {
  description = "Azure region (e.g. 'eastus', 'westeurope'). See: azure.microsoft.com/en-us/explore/global-infrastructure/geographies"
  type        = string
}

variable "plan" {
  description = "Azure VM size (e.g. 'Standard_B1s'). See: learn.microsoft.com/en-us/azure/virtual-machines/sizes"
  type        = string
}

variable "hostname" {
  description = "Instance hostname / resource name prefix."
  type        = string
}

variable "firewall_ports" {
  description = "TCP ports to open inbound from 0.0.0.0/0."
  type        = list(number)
}
