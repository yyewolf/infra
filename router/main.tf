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

  # Same secret, two consumers: this account is created here and authenticated
  # against by Home Assistant, so the value has to exist in router-sops.yaml
  # (for the router) and in the cluster's router-wol-secret-sops.yaml (for HA).
  # They are separate files because they are decrypted by different things at
  # different times — Terraform at apply, Flux at reconcile — not because the
  # secret is different. Change one and you must change the other.
  wol_password = try(data.sops_file.router_credentials.data["secrets.wol_password"], null)
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

# Wake-on-LAN, driven by Home Assistant calling the router.
#
# The previous approach — a static ARP entry mapping the upstream broadcast
# address to the all-ones MAC, so a magic packet aimed at it would be forwarded
# and re-broadcast — does not work on this router, and the failure is structural
# rather than a misconfiguration. `192.168.1.255` is the subnet broadcast of a
# directly-connected interface, so the kernel treats it as a local address and
# consumes the packet: mangle counters showed prerouting 2, forward 0,
# postrouting 0. It is never a forwarding decision, so ARP is never consulted and
# no firewall rule can change that. RFC 2644 behaviour, working as intended.
#
# `/tool wol` sidesteps the whole question by emitting the magic packet directly
# onto the interface as a real broadcast frame. Nothing is routed, so there is no
# directed broadcast to relay, no ARP entry to keep alive across reboots, and no
# scheduler — which also means device-mode's `scheduler` flag can go back to
# whatever it was before, since this needs none of it.
#
# What is declared here is only the account HA authenticates as. The wake itself
# is a command, not configuration, so it is not Terraform's to hold: HA POSTs to
# /rest/tool/wol when it wants a machine woken.
resource "routeros_system_user_group" "wol" {
  count = var.wol_user == null ? 0 : 1

  name    = "wol"
  comment = "Home Assistant: send Wake-on-LAN magic packets, nothing else"

  # `rest-api` is its own policy, separate from `api` — the latter is the older
  # binary API on 8728/8729 and is deliberately not granted. `test` is what
  # covers the /tool commands, and `read` is needed alongside it because RouterOS
  # policies do not imply one another.
  #
  # No `write`, no `policy`, no `ssh`/`ftp`/`winbox`/`web`. If the REST call comes
  # back with a permission error, add `write` before widening anything else —
  # MikroTik documents `test` as covering "ping, traceroute, bandwidth-test [...]
  # and other test commands" without naming wol specifically, so that one edge is
  # worth confirming against your version rather than assuming.
  policy = ["read", "test", "rest-api"]
}

resource "routeros_system_user" "wol" {
  count = var.wol_user == null ? 0 : 1

  name     = var.wol_user.name
  group    = routeros_system_user_group.wol[0].name
  password = local.wol_password
  comment  = "Home Assistant WoL — see flux/apps/home-assistant/router-wol-secret-sops.yaml"

  # Scoped to the one host that uses it. w-1 is host-networked, so Home Assistant
  # reaches the router as the node's own address; a credential leaked out of the
  # cluster is not usable from anywhere else on the LAN.
  address = var.wol_user.allowed_source
}

module "ip_firewall" {
  source = "./modules/ip-firewall"

  lan_interface_list       = var.lan_interface_list
  wan_interface_list       = var.wan_interface_list
  blocked_lan_destinations = var.lan_blocked_destinations
  wan_port_forwards        = var.wan_port_forwards
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
