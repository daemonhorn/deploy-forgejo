variable "region" {
  description = "AWS region (e.g. 'us-east-1' = N. Virginia)."
  type        = string
  default     = "us-east-1"
}

variable "plan" {
  description = "EC2 instance type (e.g. 't3.micro'). See: aws.amazon.com/ec2/instance-types/"
  type        = string
  default     = "t3.micro"
}

variable "hostname" {
  description = "Instance hostname / Name tag."
  type        = string
  default     = "forgejo"
}

variable "admin_ssh_public_key" {
  description = "Ed25519 public key for VPS admin SSH access. Supply via TF_VAR_admin_ssh_public_key; never commit to tfvars."
  type        = string
  sensitive   = true
}

variable "firewall_ports" {
  description = "TCP ports to open inbound. 2222 = Forgejo Git SSH on host sshd."
  type        = list(number)
  default     = [22, 80, 443, 2222]
}

variable "ip_stack" {
  description = "IP stack: 'ipv4' (default), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only)."
  type        = string
  default     = "ipv4"
}
