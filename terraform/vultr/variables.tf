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
  description = "All TCP ports to open inbound. Public ports get 0.0.0.0/0; admin_only_ports get allowed_cidrs; user_cidrs adds user_accessible_ports on top of that."
  type        = list(number)
  default     = [22, 80, 443, 2222]
}

variable "admin_only_ports" {
  description = "Subset of firewall_ports restricted to allowed_cidrs. Port 443 is admin-restricted; use user_cidrs to open it to a wider audience."
  type        = list(number)
  default     = [22, 2222, 443]
}

variable "allowed_cidrs" {
  description = "CIDRs allowed inbound on admin_only_ports. Empty list blocks all admin access (fail-closed). Written by provision.sh."
  type        = list(string)
  default     = []
}

variable "user_cidrs" {
  description = "CIDRs allowed inbound on ports 2222 and 443 (in addition to admin CIDRs). Not persisted to tfvars; supply via TF_VAR_user_cidrs or --user-cidrs on each provision run. Empty list = ports 2222/443 are admin-only (fail-closed)."
  type        = list(string)
  default     = []
}

variable "ip_stack" {
  description = "IP stack: 'ipv4' (default), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only)."
  type        = string
  default     = "ipv4"
}
