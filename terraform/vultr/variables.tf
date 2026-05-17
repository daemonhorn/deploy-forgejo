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
  description = "All TCP ports to open inbound. Public ports get 0.0.0.0/0; admin_only_ports get allowed_cidrs."
  type        = list(number)
  default     = [22, 80, 443, 2222]
}

variable "admin_only_ports" {
  description = "Subset of firewall_ports restricted to allowed_cidrs (SSH ports; 80/443 stay world-open for certbot)."
  type        = list(number)
  default     = [22, 2222]
}

variable "allowed_cidrs" {
  description = "CIDRs allowed inbound on admin_only_ports. Written by provision.sh from --admin-cidrs or auto-detected admin IP."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "ip_stack" {
  description = "IP stack: 'ipv4' (default), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only)."
  type        = string
  default     = "ipv4"
}
