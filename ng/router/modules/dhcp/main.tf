terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_ip_pool" "pool" {
  name    = var.name
  ranges  = var.pool_ranges
  comment = "${var.name} pool"
}

resource "routeros_ip_dhcp_server" "server" {
  name                      = var.name
  interface                 = var.interface
  address_pool              = routeros_ip_pool.pool.name
  lease_time                = var.lease_time
  dynamic_lease_identifiers = "client-mac,client-id"
  authoritative             = "yes"
  add_arp                   = true
}

resource "routeros_ip_dhcp_server_network" "network" {
  address    = var.subnet
  gateway    = var.gateway
  netmask    = tonumber(split("/", var.subnet)[1])
  dns_server = var.dns_servers
  domain     = var.domain
  comment    = "${var.name} network"
}
