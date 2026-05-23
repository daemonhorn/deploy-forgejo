variable "region" {
  description = "Azure region (e.g. 'eastus', 'westeurope', 'uksouth')."
  type        = string
  default     = "eastus"
}

variable "plan" {
  description = <<-EOT
    Azure VM size. Standard_B1s (1 vCPU, 1 GB RAM) is the smallest size that
    reliably runs Forgejo + PostgreSQL + nginx. Standard_B1ls (0.5 GB RAM) exists
    but risks OOM under load. See: learn.microsoft.com/en-us/azure/virtual-machines/bv1-series
  EOT
  type        = string
  default     = "Standard_B1s"
}

variable "hostname" {
  description = "VM hostname and resource group name prefix."
  type        = string
  default     = "forgejo"
}

variable "admin_ssh_public_key" {
  description = "Ed25519 public key for VM admin SSH access. Supply via TF_VAR_admin_ssh_public_key; never commit to tfvars."
  type        = string
  sensitive   = true
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
