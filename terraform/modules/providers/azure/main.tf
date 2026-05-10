terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# One resource group contains all Forgejo resources; deleting it removes everything cleanly.
resource "azurerm_resource_group" "main" {
  name     = var.hostname
  location = var.region
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.hostname}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "main" {
  name                 = "${var.hostname}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Static public IP so the Let's Encrypt IP certificate stays valid across reboots.
resource "azurerm_public_ip" "main" {
  name                = "${var.hostname}-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

locals {
  # Build a map of port → priority (100, 101, …) for the NSG dynamic block.
  # Map keys are strings (port numbers); map values carry both port and priority
  # so the content block has everything it needs without calling index().
  firewall_rules = {
    for idx, port in var.firewall_ports :
    tostring(port) => { port = port, priority = 100 + idx }
  }

  # Bootstrap script: Azure VMs cannot be created with admin_username=root, so we
  # provision as 'azureadmin' and copy the authorized_keys to root via custom_data.
  # This mirrors the AWS user_data pattern so provision.sh can SSH as root uniformly.
  root_bootstrap = base64encode(<<-EOT
    #!/bin/bash
    set -e
    while [ ! -f /home/azureadmin/.ssh/authorized_keys ]; do sleep 1; done
    mkdir -p /root/.ssh
    cp /home/azureadmin/.ssh/authorized_keys /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart ssh
  EOT
  )
}

resource "azurerm_network_security_group" "main" {
  name                = "${var.hostname}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  dynamic "security_rule" {
    for_each = local.firewall_rules
    content {
      name                       = "allow-${security_rule.key}"
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(security_rule.value.port)
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_network_interface" "main" {
  name                = "${var.hostname}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "main"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

# Associate NSG at the subnet level rather than per-NIC.
# With a per-NIC association, Terraform can destroy the NIC and NSG in parallel;
# Azure rejects the NSG deletion if the NIC's association record hasn't cleared yet
# (even after the NIC DELETE returns 200). The subnet association resource depends
# on both the subnet and the NSG, so Terraform's graph guarantees it is destroyed
# before either — the NIC has no NSG reference and is not in that ordering chain.
resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_linux_virtual_machine" "main" {
  name                            = var.hostname
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.plan
  admin_username                  = "azureadmin"
  disable_password_authentication = true

  network_interface_ids = [azurerm_network_interface.main.id]

  admin_ssh_key {
    username   = "azureadmin"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    # Standard_LRS (HDD) is the lowest-cost disk tier; sufficient for a single-user Forgejo.
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # Debian 12 (Bookworm) from the official Debian publisher on Azure Marketplace.
  # version = "latest" resolves to the newest published patch at apply time.
  source_image_reference {
    publisher = "Debian"
    offer     = "debian-12"
    sku       = "12-gen2"
    version   = "latest"
  }

  # Copies SSH key to root and re-enables PermitRootLogin prohibit-password
  # so provision.sh can connect as root consistently across all providers.
  custom_data = local.root_bootstrap

  tags = { Name = var.hostname }
}
