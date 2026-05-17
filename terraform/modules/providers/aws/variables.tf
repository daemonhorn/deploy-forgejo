# Standard provider contract — all provider modules must accept these exact variables.

variable "ssh_public_key" {
  description = "Ed25519 public key material to upload for admin VPS access."
  type        = string
}

variable "region" {
  description = "AWS region (e.g. 'us-east-1' = N. Virginia, 'us-west-2' = Oregon)."
  type        = string
}

variable "plan" {
  description = "EC2 instance type (e.g. 't3.micro'). See: aws.amazon.com/ec2/instance-types/"
  type        = string
}

variable "hostname" {
  description = "Instance hostname / Name tag."
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
  description = "CIDRs permitted inbound on admin_only_ports. provision.sh writes the admin network; default allows all (backwards-compatible)."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs must contain at least one CIDR."
  }
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
