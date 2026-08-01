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
  # binary API on 8728/8729 and is deliberately not granted. `read` is needed
  # alongside anything else because RouterOS policies do not imply one another.
  #
  # `write` is here reluctantly and is the widest thing in this file. `read`,
  # `test` and `rest-api` alone got "std failure: not allowed (9)" from
  # /tool wol; MikroTik does not document which policy the command needs, and
  # `test` — "ping, traceroute, bandwidth-test [...] and other test commands" —
  # turns out not to cover it.
  #
  # Understand what this grants: `write` is write access to the whole router
  # configuration except user management. This account cannot create users or
  # change policies (no `policy` policy), and cannot log in over
  # ssh/ftp/winbox/web, but it CAN rewrite firewall rules and NAT. It is pinned
  # to 10.200.0.14 below, so it is only usable from w-1 — but Home Assistant is
  # a privileged host-networked container running a lot of third-party
  # integrations, so treat "HA is compromised" as "the router is configurable by
  # the attacker" and size that risk accordingly.
  #
  # See the note on the user below for the way to avoid this grant entirely.
  policy = ["read", "write", "test", "rest-api"]
}

resource "routeros_system_user" "wol" {
  count = var.wol_user == null ? 0 : 1

  name     = var.wol_user.name
  group    = routeros_system_user_group.wol[0].name
  password = local.wol_password
  comment  = "Home Assistant WoL — see flux/apps/home-assistant/router-wol-secret-sops.yaml"

  # Scoped to the one host that uses it. w-1 is host-networked, so Home Assistant
  # reaches the router as the node's own address; a credential leaked out of the
  # cluster is not usable from anywhere else on the LAN. This is the only thing
  # bounding the `write` policy above, so do not relax it.
  address = var.wol_user.allowed_source
}

# AVOIDING ALL OF THE ABOVE
#
# There is a way to wake the target that needs no router account, no REST call
# and no `write` policy: unicast Wake-on-LAN. A magic packet does not have to
# arrive in a broadcast frame — the NIC matches on the packet's contents, not the
# frame's destination. Sent as ordinary unicast UDP to the target's own address
# on port 9, it is routed and forwarded like any other packet, which the mangle
# counters already proved works in that direction.
#
# The reason this is not the obvious default is ARP: a sleeping host does not
# answer, so the router cannot resolve its MAC and drops the packet. A STATIC ARP
# entry for the target — its address mapped to its real MAC on ether1, not the
# all-ones MAC the old broadcast attempt used — removes that dependency, and the
# packet goes straight out.
#
# If that works, Home Assistant's built-in `wake_on_lan` integration can send it
# directly with no rest_command, and this user, its group and the whole
# credential path can be deleted. It needs the target to hold a stable address
# (DHCP reservation upstream or a static lease) and the same script-plus-
# scheduler workaround the old ARP entry used, since the provider still has no
# /ip/arp resource.
#
# Untested here. Worth ten minutes before accepting the `write` grant above:
#
#     /ip arp add address=<target-ip> mac-address=<target-mac> interface=ether1
#     # then, from Home Assistant, a magic packet to <target-ip>:9

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
