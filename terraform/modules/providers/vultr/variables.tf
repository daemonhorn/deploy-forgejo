# Standard provider contract — all provider modules must accept these exact variables.

variable "ssh_public_key" {
  description = "Ed25519 public key material to upload for admin VPS access."
  type        = string
}

variable "region" {
  description = "Vultr region slug (e.g. 'ewr' = New Jersey, 'lax' = Los Angeles)."
  type        = string
}

variable "plan" {
  description = "Vultr plan slug (e.g. 'vc2-1c-1gb'). See: vultr.com/api/#tag/plans."
  type        = string
}

variable "hostname" {
  description = "VPS hostname label."
  type        = string
}

variable "firewall_ports" {
  description = "TCP ports to open inbound from 0.0.0.0/0."
  type        = list(number)
}
