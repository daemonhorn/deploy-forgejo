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

# ── VPC selection ─────────────────────────────────────────────────────────────
# ipv4 mode: use the account's default VPC (backwards-compatible with existing state).
# dual/ipv6 mode: create a dedicated VPC with an Amazon-provided IPv6 /56 CIDR.
#   The default VPC cannot be assigned an IPv6 CIDR via Terraform, so a dedicated
#   VPC is required for any IPv6 configuration.

data "aws_vpc" "default" {
  count   = var.ip_stack == "ipv4" ? 1 : 0
  default = true
}

resource "aws_vpc" "main" {
  count                            = var.ip_stack != "ipv4" ? 1 : 0
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_hostnames             = true
  tags                             = { Name = "${var.hostname}-vpc" }
}

resource "aws_internet_gateway" "main" {
  count  = var.ip_stack != "ipv4" ? 1 : 0
  vpc_id = aws_vpc.main[0].id
  tags   = { Name = "${var.hostname}-igw" }
}

resource "aws_subnet" "main" {
  count  = var.ip_stack != "ipv4" ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  cidr_block = "10.0.1.0/24"
  # Carve one /64 from the VPC's assigned /56 block.
  ipv6_cidr_block = cidrsubnet(aws_vpc.main[0].ipv6_cidr_block, 8, 1)

  # Auto-assign IPv4 for dual mode; ipv6-only instances have no public IPv4.
  map_public_ip_on_launch         = var.ip_stack == "dual"
  assign_ipv6_address_on_creation = true

  tags = { Name = "${var.hostname}-subnet" }
}

resource "aws_route_table" "main" {
  count  = var.ip_stack != "ipv4" ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.main[0].id
  }

  tags = { Name = "${var.hostname}-rt" }
}

resource "aws_route_table_association" "main" {
  count          = var.ip_stack != "ipv4" ? 1 : 0
  subnet_id      = aws_subnet.main[0].id
  route_table_id = aws_route_table.main[0].id
}

locals {
  vpc_id    = var.ip_stack == "ipv4" ? data.aws_vpc.default[0].id : aws_vpc.main[0].id
  subnet_id = var.ip_stack != "ipv4" ? aws_subnet.main[0].id : null

  # Split allowed_cidrs into IPv4 and IPv6.
  allowed_v4_cidrs = [for c in var.allowed_cidrs : c if !strcontains(c, ":")]
  allowed_v6_cidrs = [for c in var.allowed_cidrs : c if strcontains(c, ":")]

  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]
}

# ── Key pair ──────────────────────────────────────────────────────────────────
resource "aws_key_pair" "admin" {
  key_name   = "${var.hostname}-admin"
  public_key = var.ssh_public_key
}

# ── Security group ────────────────────────────────────────────────────────────
resource "aws_security_group" "main" {
  name        = "${var.hostname}-forgejo"
  description = "Forgejo server inbound rules"
  vpc_id      = local.vpc_id

  # World-open IPv4 ingress for public ports — omitted in ipv6-only mode.
  dynamic "ingress" {
    for_each = var.ip_stack != "ipv6" ? { for p in local.public_ports : tostring(p) => p } : {}
    iterator = rule
    content {
      from_port   = rule.value
      to_port     = rule.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # World-open IPv6 ingress for public ports — added in dual and ipv6-only modes.
  dynamic "ingress" {
    for_each = var.ip_stack != "ipv4" ? { for p in local.public_ports : tostring(p) => p } : {}
    iterator = rule
    content {
      from_port        = rule.value
      to_port          = rule.value
      protocol         = "tcp"
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  # Admin-only IPv4 ingress — one rule per admin port, CIDR list restricted to admin network.
  dynamic "ingress" {
    for_each = var.ip_stack != "ipv6" && length(local.allowed_v4_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    iterator = rule
    content {
      from_port   = rule.value
      to_port     = rule.value
      protocol    = "tcp"
      cidr_blocks = local.allowed_v4_cidrs
    }
  }

  # Admin-only IPv6 ingress — one rule per admin port.
  dynamic "ingress" {
    for_each = var.ip_stack != "ipv4" && length(local.allowed_v6_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    iterator = rule
    content {
      from_port        = rule.value
      to_port          = rule.value
      protocol         = "tcp"
      ipv6_cidr_blocks = local.allowed_v6_cidrs
    }
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.hostname}-forgejo" }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Instance ──────────────────────────────────────────────────────────────────
resource "aws_instance" "main" {
  ami           = data.aws_ami.debian12.id
  instance_type = var.plan
  key_name      = aws_key_pair.admin.key_name

  vpc_security_group_ids = [aws_security_group.main.id]
  subnet_id              = local.subnet_id

  # ipv6-only: no public IPv4 (instance is reachable only via IPv6).
  associate_public_ip_address = var.ip_stack != "ipv6"
  # dual/ipv6: request one IPv6 address from the subnet pool.
  ipv6_address_count = var.ip_stack != "ipv4" ? 1 : 0

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
