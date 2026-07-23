terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_ip_firewall_filter" "input_established" {
  action           = "accept"
  chain            = "input"
  comment          = "defconf: accept established,related,untracked"
  connection_state = "established,related,untracked"
}

resource "routeros_ip_firewall_filter" "input_drop_invalid" {
  action           = "drop"
  chain            = "input"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
}

resource "routeros_ip_firewall_filter" "input_icmp" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept ICMP"
  protocol = "icmp"
}

resource "routeros_ip_firewall_filter" "input_loopback" {
  action      = "accept"
  chain       = "input"
  comment     = "defconf: accept to local loopback (for CAPsMAN)"
  dst_address = "127.0.0.1"
}

resource "routeros_ip_firewall_filter" "input_services" {
  action   = "accept"
  chain    = "input"
  dst_port = join(",", var.input_allowed_ports)
  protocol = "tcp"
}

resource "routeros_ip_firewall_filter" "input_drop_not_lan" {
  action            = "drop"
  chain             = "input"
  comment           = "defconf: drop all not coming from LAN"
  in_interface_list = "!${var.lan_interface_list}"
}

resource "routeros_ip_firewall_filter" "forward_ipsec_in" {
  action       = "accept"
  chain        = "forward"
  comment      = "defconf: accept in ipsec policy"
  ipsec_policy = "in,ipsec"
}

resource "routeros_ip_firewall_filter" "forward_ipsec_out" {
  action       = "accept"
  chain        = "forward"
  comment      = "defconf: accept out ipsec policy"
  ipsec_policy = "out,ipsec"
}

resource "routeros_ip_firewall_filter" "forward_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  comment          = "defconf: fasttrack"
  connection_state = "established,related"
}

resource "routeros_ip_firewall_filter" "forward_established" {
  action           = "accept"
  chain            = "forward"
  comment          = "defconf: accept established,related, untracked"
  connection_state = "established,related,untracked"
}

resource "routeros_ip_firewall_filter" "forward_drop_invalid" {
  action           = "drop"
  chain            = "forward"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
}

resource "routeros_ip_firewall_filter" "forward_drop_wan_new" {
  action               = "drop"
  chain                = "forward"
  comment              = "defconf: drop all from WAN not DSTNATed"
  connection_nat_state = "!dstnat"
  connection_state     = "new"
  in_interface_list    = var.wan_interface_list
}

resource "routeros_ip_firewall_nat" "srcnat_masquerade" {
  action            = "masquerade"
  chain             = "srcnat"
  comment           = "defconf: masquerade"
  ipsec_policy      = "out,none"
  out_interface_list = var.wan_interface_list
}
