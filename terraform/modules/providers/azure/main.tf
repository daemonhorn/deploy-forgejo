terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# One resource group contains all Forgejo resources; deleting it removes everything cleanly.
resource "azurerm_resource_group" "main" {
  name     = var.hostname
  location = var.region
}

# Azure's control plane can return 200 for resource group creation but not yet
# propagate the group to child resource APIs, causing sporadic 404 Read-after-Create
# failures (Terraform reports "Root object was present, but now absent").
# A 30-second pause after the RG is ready eliminates this race for all child resources.
# See: https://github.com/hashicorp/terraform-provider-azurerm/issues/27087
resource "time_sleep" "rg_propagation" {
  depends_on      = [azurerm_resource_group.main]
  create_duration = "30s"
}

resource "azurerm_virtual_network" "main" {
  name     = "${var.hostname}-vnet"
  location = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # dual/ipv6 mode: add a ULA IPv6 /48; Azure maps private IPv6 addresses from
  # this range to the public IPv6 address on the Standard SKU public IP resource.
  address_space = var.ip_stack != "ipv4" ? ["10.0.0.0/16", "ace:cab:deca::/48"] : ["10.0.0.0/16"]

  # Inline subnet avoids the eventual-consistency race where the VNet creation
  # API returns 200 but the resource isn't yet visible when a separate
  # azurerm_subnet resource immediately POSTs against it (404 on polling).
  # The NSG is associated here so VNet destruction atomically removes the
  # subnet + its NSG link before the NSG delete runs — no ordering race.
  subnet {
    name           = "${var.hostname}-subnet"
    address_prefixes = var.ip_stack != "ipv4" ? ["10.0.1.0/24", "ace:cab:deca:deed::/64"] : ["10.0.1.0/24"]
    security_group = azurerm_network_security_group.main.id
  }

  # Azure may back-fill subnet defaults on subsequent reads; ignore to prevent
  # spurious drift on `terraform plan` after the initial apply.
  # NOTE: changing ip_stack on an existing deployment requires destroy+apply
  # because this lifecycle block prevents in-place subnet prefix updates.
  lifecycle {
    ignore_changes = [subnet]
  }
}

# Static public IPv4 so the Let's Encrypt IP certificate stays valid across reboots.
resource "azurerm_public_ip" "main" {
  name                = "${var.hostname}-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv4"
  depends_on          = [time_sleep.rg_propagation]
}

# Static public IPv6 — only created in dual and ipv6-only modes.
# Standard SKU public IPs support only one IP family per resource, so a
# separate resource is required alongside the IPv4 public IP.
resource "azurerm_public_ip" "ipv6" {
  count               = var.ip_stack != "ipv4" ? 1 : 0
  name                = "${var.hostname}-ip6"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv6"
  depends_on          = [time_sleep.rg_propagation]
}

locals {
  # Build a map of port → priority (100, 101, …) for the NSG dynamic block.
  # Map keys are strings (port numbers); map values carry both port and priority
  # so the content block has everything it needs without calling index().
  firewall_rules = {
    for idx, port in var.firewall_ports :
    tostring(port) => { port = port, priority = 100 + idx }
  }

  # Extract the inline subnet ID from the VNet resource.
  subnet_id = one([for s in azurerm_virtual_network.main.subnet : s.id])

  # Bootstrap script: Azure VMs cannot be created with admin_username=root, so we
  # provision as 'azureadmin' and copy the authorized_keys to root via custom_data.
  # This mirrors the AWS user_data pattern so provision.sh can SSH as root uniformly.
  root_bootstrap = base64encode(<<-EOT
    #!/bin/bash
    set -e
    for i in $(seq 1 60); do
      [ -f /home/azureadmin/.ssh/authorized_keys ] && break
      sleep 1
    done
    [ -f /home/azureadmin/.ssh/authorized_keys ] || { echo "ERROR: authorized_keys never appeared" >&2; exit 1; }
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
  depends_on          = [time_sleep.rg_propagation]

  # source_address_prefix = "*" matches any source including IPv6, so no
  # separate IPv6 rules are needed — NSG rules apply to both address families.
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
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    private_ip_address_version    = "IPv4"
    public_ip_address_id          = azurerm_public_ip.main.id
    # primary must be true when multiple ip_configuration blocks are present.
    primary = true
  }

  dynamic "ip_configuration" {
    for_each = var.ip_stack != "ipv4" ? [1] : []
    content {
      name                          = "ipv6"
      subnet_id                     = local.subnet_id
      private_ip_address_allocation = "Dynamic"
      private_ip_address_version    = "IPv6"
      public_ip_address_id          = azurerm_public_ip.ipv6[0].id
    }
  }
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

  # Empty block enables boot diagnostics with a managed storage account,
  # which is required in azurerm 4.x for serial console access.
  boot_diagnostics {}

  tags = { Name = var.hostname }
}
