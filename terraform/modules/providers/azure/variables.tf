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
  description = "All TCP ports to open inbound. Public ports get 0.0.0.0/0; admin_only_ports get allowed_cidrs."
  type        = list(number)
}

variable "admin_only_ports" {
  description = "Subset of firewall_ports restricted to allowed_cidrs (default: SSH ports only)."
  type        = list(number)
  default     = [22, 2222]
}

variable "allowed_cidrs" {
  description = "CIDRs permitted inbound on admin_only_ports. Empty list blocks all admin access (fail-closed default). provision.sh populates this from --admin-cidrs or auto-detected admin IP."
  type        = list(string)
  default     = []
}

variable "user_cidrs" {
  description = "CIDRs permitted inbound on user_accessible_ports (2222, 443). Not persisted to tfvars; pass via --user-cidrs on each provision run. Empty list means user ports are admin-only (fail-closed)."
  type        = list(string)
  default     = []
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
