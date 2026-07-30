terraform {
  required_version = ">= 1.0"
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}

locals {
  lan_subnet        = var.lan_subnet
  lan_prefix_length = tonumber(split("/", var.lan_subnet)[1])
  lan_gateway       = cidrhost(var.lan_subnet, 1)
}

resource "routeros_system_identity" "router" {
  name = "mikrotik-router"
}

resource "routeros_interface_bridge" "lan" {
  name    = "bridge"
  comment = "LAN bridge"
}

resource "routeros_interface_bridge_port" "lan_ports" {
  for_each  = toset(var.lan_interfaces)
  bridge    = routeros_interface_bridge.lan.name
  interface = each.key
  comment   = each.key
}

resource "routeros_ip_address" "lan" {
  address   = "${local.lan_gateway}/${local.lan_prefix_length}"
  interface = routeros_interface_bridge.lan.name
  comment   = "LAN gateway"

  lifecycle {
    ignore_changes = [vrf]
  }
}

module "dhcp" {
  source = "./modules/dhcp"

  interface   = routeros_interface_bridge.lan.name
  subnet      = local.lan_subnet
  gateway     = local.lan_gateway
  pool_ranges = var.lan_dhcp_pool_ranges
  dns_servers = [local.lan_gateway]
  lease_time  = var.lan_dhcp_lease_time

  depends_on = [routeros_ip_address.lan]
}

module "wan" {
  source = "./modules/wan"

  interface_name = var.wan_interface
  hostname       = var.wan_hostname
}

module "ip_firewall" {
  source = "./modules/ip-firewall"

  lan_interface_list       = var.lan_interface_list
  wan_interface_list       = var.wan_interface_list
  blocked_lan_destinations = var.lan_blocked_destinations
}

module "ipv6_firewall" {
  source = "./modules/ipv6-firewall"

  lan_interface_list = var.lan_interface_list
}

data "sops_file" "wg_identities" {
  source_file = "${path.module}/../wireguard/identities-sops.yaml"
}

locals {
  wg_raw         = yamldecode(data.sops_file.wg_identities.raw)
  wg_self_name   = "home-router-0"
  wg_identities  = nonsensitive(local.wg_raw.identities)
  wg_self        = local.wg_identities[local.wg_self_name]
  wg_self_secret = local.wg_raw.secrets[local.wg_self_name]
  wg_peers       = { for k, v in local.wg_identities : k => v if k != local.wg_self_name }
}

module "wireguard" {
  source = "./modules/wireguard"

  interface_name    = "wireguard1"
  interface_list    = var.lan_interface_list
  comment           = local.wg_self_name
  private_key       = local.wg_self_secret.private_key
  listen_port       = local.wg_self.listen_port
  interface_address = local.wg_self.address
  peers             = local.wg_peers
}
