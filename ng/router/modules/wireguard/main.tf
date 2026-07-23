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

resource "routeros_interface_wireguard_peer" "peers" {
  for_each = var.peers

  interface         = routeros_interface_wireguard.wg.name
  public_key        = each.value.public_key
  allowed_address   = [each.value.address]
  comment           = each.key
  endpoint_address  = try(split(":", each.value.endpoint)[0], null)
  endpoint_port     = try(split(":", each.value.endpoint)[1], null)
}
