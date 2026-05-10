terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Latest Debian 12 (Bookworm) x86_64 HVM AMI from the official Debian AWS account.
# Owner 136693071363 is the Debian project's canonical AWS publisher account.
data "aws_ami" "debian12" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_key_pair" "admin" {
  key_name   = "${var.hostname}-admin"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "main" {
  name        = "${var.hostname}-forgejo"
  description = "Forgejo server inbound rules"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.firewall_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.hostname}-forgejo" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "main" {
  ami                         = data.aws_ami.debian12.id
  instance_type               = var.plan
  key_name                    = aws_key_pair.admin.key_name
  vpc_security_group_ids      = [aws_security_group.main.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${var.hostname}-root" }
  }

  # Debian AMIs default to the 'admin' user. This script copies their
  # authorized_keys to root so provision.sh can SSH as root consistently
  # across providers without conditional sudo handling.
  # cloud-init writes admin's authorized_keys before running user_data;
  # the wait loop guards against any ordering edge cases.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    while [ ! -f /home/admin/.ssh/authorized_keys ]; do sleep 1; done
    mkdir -p /root/.ssh
    cp /home/admin/.ssh/authorized_keys /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart ssh
  EOF

  tags = { Name = var.hostname }
}
