#############################################################################
# CONFIGURATION
#############################################################################

# Set azurerm provider to use version 2.x
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 2.0"

    }
  }
}

#############################################################################
# VARIABLES
#############################################################################

variable "prefix" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

# CIDR range for first virtual network
variable "vnet1_cidr_range" {
  type    = string
  default = "10.1.0.0/16"
}

# Subnet prefixes for first virtual network
# Must be in the CIDR range
# TODO - change to subnet calculation
variable "vnet1_subnet_prefixes" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24"]
}

# CIDR range for second virtual network
variable "vnet2_cidr_range" {
  type    = string
  default = "10.2.0.0/16"
}

# Subnet prefixes for second virtual network
# Must be in the CIDR range
# TODO - change to subnet calculation
variable "vnet2_subnet_prefixes" {
  type    = list(string)
  default = ["10.2.0.0/24", "10.2.1.0/24"]
}


#############################################################################
# PROVIDERS
#############################################################################

# Set default azurerm provider to use 2.X
provider "azurerm" {
  version = "~> 2.0"
  features {}
}

#############################################################################
# LOCALS
#############################################################################

# Configure locals based on prefix for resource group, subnet, and server names
# TODO - add randomize string

locals {
  resource_group_name = "${var.prefix}-vnetpeering"
  subnet_names        = ["${var.prefix}-subnet1", "${var.prefix}-subnet2"]
  server1_name        = "${lower(var.prefix)}-${random_integer.dns_num.result}-server1"
  server2_name        = "${lower(var.prefix)}-${random_integer.dns_num.result}-server2"
}

#############################################################################
# RESOURCES
#############################################################################

# Random integer for naming unique components
resource "random_integer" "dns_num" {
  min = 10000
  max = 99999
}

# Password to be used for servers
resource "random_password" "server_pass" {
  length  = 12
  special = false
}

# Resource group for all other resources
resource "azurerm_resource_group" "vnetpeering" {
  name     = local.resource_group_name
  location = var.location
}

# Create first virtual network called vnet1
module "vnet1" {
  source              = "Azure/network/azurerm"
  version             = "3.2.1"
  resource_group_name = azurerm_resource_group.vnetpeering.name
  vnet_name           = "vnet1"
  address_space       = var.vnet1_cidr_range
  subnet_prefixes     = var.vnet1_subnet_prefixes
  subnet_names        = local.subnet_names

  tags = {
  }

  # Required for Terraform 0.13 and up
  depends_on = [azurerm_resource_group.vnetpeering]
}

# Create second virtual network called vnet2
module "vnet2" {
  source              = "Azure/network/azurerm"
  version             = "3.2.1"
  resource_group_name = azurerm_resource_group.vnetpeering.name
  vnet_name           = "vnet2"
  address_space       = var.vnet2_cidr_range
  subnet_prefixes     = var.vnet2_subnet_prefixes
  subnet_names        = local.subnet_names

  tags = {
  }

  # Required for Terraform 0.13 and up
  depends_on = [azurerm_resource_group.vnetpeering]
}

# Public IP address for server1
# User will SSH into server1 using this address
# TODO - replace with DNS name?
resource "azurerm_public_ip" "server1" {
  name                = local.server1_name
  resource_group_name = azurerm_resource_group.vnetpeering.name
  location            = azurerm_resource_group.vnetpeering.location
  allocation_method   = "Static"
}

# Network interface for server1 attached to first subnet in vnet1
resource "azurerm_network_interface" "server1" {
  name                = "${var.prefix}-server1"
  location            = azurerm_resource_group.vnetpeering.location
  resource_group_name = azurerm_resource_group.vnetpeering.name

  ip_configuration {
    name                          = "config1"
    subnet_id                     = module.vnet1.vnet_subnets[0]
    private_ip_address_allocation = "Static"
    # TODO - change to calulation based on subnet IP address range
    # TODO - include private IP address in output?
    private_ip_address = "10.1.0.4"
    public_ip_address_id = azurerm_public_ip.server1.id
  }
}

# Network interface for server2 attached to first subnet in vnet2
resource "azurerm_network_interface" "server2" {
  name                = "${var.prefix}-server2"
  location            = azurerm_resource_group.vnetpeering.location
  resource_group_name = azurerm_resource_group.vnetpeering.name

  ip_configuration {
    name                          = "config1"
    subnet_id                     = module.vnet2.vnet_subnets[0]
    private_ip_address_allocation = "Static"
    private_ip_address = "10.2.0.4"
  }
}

# Create security group for server1 to allow SSH
resource "azurerm_network_security_group" "server1" {
  name                = "${var.prefix}-server1"
  location            = azurerm_resource_group.vnetpeering.location
  resource_group_name = azurerm_resource_group.vnetpeering.name
}

# Security group rule allowing SSH traffic
resource "azurerm_network_security_rule" "server1" {
  name                        = "allow-ssh"
  priority                    = 100
  direction                   = "InBound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vnetpeering.name
  network_security_group_name = azurerm_network_security_group.server1.name
}

# Associate security group rule with server1's NIC
resource "azurerm_network_interface_security_group_association" "server1" {
  network_interface_id      = azurerm_network_interface.server1.id
  network_security_group_id = azurerm_network_security_group.server1.id
}

# Create server1 virtual machine
resource "azurerm_virtual_machine" "server1" {
  name                  = "server1"
  location              = azurerm_resource_group.vnetpeering.location
  resource_group_name   = azurerm_resource_group.vnetpeering.name
  network_interface_ids = [azurerm_network_interface.server1.id]
  vm_size               = "Standard_DS1_v2"
  
  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "${var.prefix}-server1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = local.server1_name
    admin_username = "pluralsight"
    admin_password = random_password.server_pass.result
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
}

# Create server2 virtual machine
resource "azurerm_virtual_machine" "server2" {
  name                  = "server2"
  location              = azurerm_resource_group.vnetpeering.location
  resource_group_name   = azurerm_resource_group.vnetpeering.name
  network_interface_ids = [azurerm_network_interface.server2.id]
  vm_size               = "Standard_DS1_v2"
  
  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "${var.prefix}-server2"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = local.server2_name
    admin_username = "pluralsight"
    admin_password = random_password.server_pass.result
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
}

#############################################################################
# OUTPUTS
#############################################################################

output "server1_public_ip" {
  value = azurerm_public_ip.server1.ip_address
}

output "server1_password" {
  value = random_password.server_pass.result
}