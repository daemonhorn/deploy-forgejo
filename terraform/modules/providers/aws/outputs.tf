# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Instance public IP address."
  value       = aws_instance.main.public_ip
}

output "ssh_user" {
  description = "SSH login user. user_data bootstraps root access so provision.sh is provider-agnostic."
  value       = "root"
}

output "instance_id" {
  description = "EC2 instance ID for lifecycle operations."
  value       = aws_instance.main.id
}
