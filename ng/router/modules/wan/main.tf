terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_interface_ethernet" "wan" {
  factory_name = var.interface_name
  name         = var.interface_name
  arp          = "enabled"
}

resource "routeros_ip_dhcp_client_option" "wan_hostname" {
  name  = "wan-hostname"
  code  = 12
  value = "s'${var.hostname}'"
}

resource "routeros_ip_dhcp_client" "wan" {
  interface    = var.interface_name
  use_peer_dns = true
  use_peer_ntp = true
  dhcp_options = "wan-hostname,clientid"
}

resource "routeros_ip_dns" "dns" {
  mdns_repeat_ifaces = [var.interface_name]
}
