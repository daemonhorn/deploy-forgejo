variable "vultr_api_key" {
  description = "Vultr API key. Supply via TF_VAR_vultr_api_key env var; never commit to tfvars."
  type        = string
  sensitive   = true
  default     = ""
}

variable "region" {
  description = "Provider-specific region identifier (e.g. 'ewr' for Vultr New Jersey)."
  type        = string
}

variable "plan" {
  description = "Provider-specific instance size (e.g. 'vc2-1c-1gb' for Vultr)."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "hostname" {
  description = "VPS hostname label."
  type        = string
  default     = "forgejo"
}

variable "admin_ssh_public_key" {
  description = "Ed25519 public key material for VPS admin SSH access (uploaded to cloud provider)."
  type        = string
}

variable "firewall_ports" {
  description = "TCP ports to open inbound. 2222 = Forgejo Git SSH on host sshd."
  type        = list(number)
  default     = [22, 80, 443, 2222]
}
