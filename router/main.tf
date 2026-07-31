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

# Maps the upstream broadcast address to the all-ones MAC, which is what turns a
# routed packet aimed at it into an actual layer-2 broadcast on the WAN segment.
# Without it RouterOS cannot resolve the next hop for a directed broadcast and
# drops the packet.
#
# This is a script plus a startup schedule rather than a declared entry because
# the provider has no resource for `/ip/arp` — only a read-only data source, and
# there is no generic escape hatch to reach an unmodelled path. So Terraform
# owns the *script*, not the ARP table: `terraform apply` will not converge a
# hand-edited or missing entry, and drift here is invisible to `plan`. The
# script is written to be idempotent and the schedule re-runs it on every boot,
# which covers the case that actually happens (the entry is in RAM and does not
# survive a reboot).
#
# After an apply that creates or changes this, run it once to install the entry
# without waiting for a reboot:
#
#     /system script run wol-relay-arp
#
# The interface is the WAN interface, not the LAN bridge: the frame has to go out
# onto the segment the address belongs to, which is the one upstream of us.
#
# Behaviour varies between RouterOS versions — some drop directed broadcasts to a
# connected subnet before ARP is ever consulted, in which case this is inert and
# waking the host needs `/tool wol` driven from Home Assistant instead. Send a
# magic packet and confirm before assuming it works.
resource "routeros_system_script" "wol_relay_arp" {
  count = var.wol_relay == null ? 0 : 1

  name    = "wol-relay-arp"
  comment = "WoL relay: broadcast to the upstream segment"
  # `write` to add the entry, `read` for the `find` that makes it idempotent,
  # `test` because /ip/arp is grouped under it. Nothing wider.
  policy = ["read", "write", "test"]

  source = <<-EOT
    :local addr "${var.wol_relay.address}"
    :local iface "${var.wan_interface}"
    /ip arp remove [find where address=$addr and interface=$iface]
    /ip arp add address=$addr mac-address=FF:FF:FF:FF:FF:FF interface=$iface comment="WoL relay"
  EOT
}

resource "routeros_system_scheduler" "wol_relay_arp" {
  count = var.wol_relay == null ? 0 : 1

  name       = "wol-relay-arp"
  comment    = "Reinstall the WoL relay ARP entry, which does not survive a reboot"
  on_event   = routeros_system_script.wol_relay_arp[0].name
  start_time = "startup"
  policy     = ["read", "write", "test"]
}

module "ip_firewall" {
  source = "./modules/ip-firewall"

  lan_interface_list       = var.lan_interface_list
  wan_interface_list       = var.wan_interface_list
  blocked_lan_destinations = var.lan_blocked_destinations
  directed_broadcast_relay = var.wol_relay
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
