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
  description = "TCP ports to open inbound from 0.0.0.0/0."
  type        = list(number)
}
