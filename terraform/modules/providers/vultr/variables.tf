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

variable "ip_stack" {
  description = "IP stack: 'ipv4' (IPv4 only), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only — firewall blocks IPv4, IPv6 used for provisioning and TLS)."
  type        = string
  default     = "ipv4"
  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_stack)
    error_message = "ip_stack must be 'ipv4', 'ipv6', or 'dual'."
  }
}
