terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_interface_wireguard" "wg" {
  name        = var.interface_name
  private_key = var.private_key
  listen_port = var.listen_port
  comment     = var.comment
}

resource "routeros_ip_address" "wg_address" {
  address   = var.interface_address
  interface = routeros_interface_wireguard.wg.name
  comment   = var.comment
}

# Without this the tunnel counts as "not LAN" and the input chain drops
# anything a peer sends to the router itself.
resource "routeros_interface_list_member" "wg" {
  count = var.interface_list == null ? 0 : 1

  interface = routeros_interface_wireguard.wg.name
  list      = var.interface_list
  comment   = var.comment
}

locals {
  # RouterOS does not turn allowed-address into routes, so anything a peer
  # advertises needs a static route or the router falls back to its default
  # gateway and masquerades tunnel traffic out the WAN.
  peer_routes = merge([
    for name, peer in var.peers : {
      for prefix in concat([peer.address], peer.routes) :
      "${name}/${prefix}" => { peer = name, prefix = prefix }
    }
  ]...)
}

resource "routeros_ip_route" "peers" {
  for_each = local.peer_routes

  dst_address = each.value.prefix
  gateway     = routeros_interface_wireguard.wg.name
  comment     = "wireguard: ${each.value.peer}"

  depends_on = [routeros_interface_wireguard_peer.peers]
}

resource "routeros_interface_wireguard_peer" "peers" {
  for_each = var.peers

  interface  = routeros_interface_wireguard.wg.name
  public_key = each.value.public_key
  comment    = each.key

  # Only what actually lives behind the peer. Listing the local LAN here would
  # send LAN-destined traffic into the tunnel instead of onto the bridge.
  allowed_address = concat([each.value.address], each.value.routes)

  endpoint_address = try(split(":", each.value.endpoint)[0], null)
  endpoint_port    = try(split(":", each.value.endpoint)[1], null)

  # We sit behind the ISP router, so peers we dial only stay reachable
  # inbound while the NAT mapping is kept alive.
  persistent_keepalive = try(each.value.endpoint, "") != "" ? var.persistent_keepalive : null
}
