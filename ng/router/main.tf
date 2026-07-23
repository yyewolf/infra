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
  address   = "10.200.0.1/24"
  interface = routeros_interface_bridge.lan.name
  comment   = "LAN gateway"

  lifecycle {
    ignore_changes = [vrf]
  }
}

module "wan" {
  source = "./modules/wan"

  interface_name = var.wan_interface
  hostname       = var.wan_hostname
}

module "ip_firewall" {
  source = "./modules/ip-firewall"

  lan_interface_list = var.lan_interface_list
  wan_interface_list = var.wan_interface_list
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
  lan_subnet     = "10.200.0.0/24"
}

module "wireguard" {
  source = "./modules/wireguard"

  interface_name    = "wireguard1"
  comment           = local.wg_self_name
  private_key       = local.wg_self_secret.private_key
  listen_port       = local.wg_self.listen_port
  interface_address = local.wg_self.address
  lan_subnet        = local.lan_subnet
  peers             = local.wg_peers
}
