terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_ipv6_firewall_addr_list" "bad_unspecified" {
  address = "::/128"
  list    = "bad_ipv6"
  comment = "defconf: unspecified address"
}

resource "routeros_ipv6_firewall_addr_list" "bad_loopback" {
  address = "::1/128"
  list    = "bad_ipv6"
  comment = "defconf: lo"
}

resource "routeros_ipv6_firewall_addr_list" "bad_site_local" {
  address = "fec0::/10"
  list    = "bad_ipv6"
  comment = "defconf: site-local"
}

resource "routeros_ipv6_firewall_addr_list" "bad_ipv4_mapped" {
  address = "::ffff:0.0.0.0/96"
  list    = "bad_ipv6"
  comment = "defconf: ipv4-mapped"
}

resource "routeros_ipv6_firewall_addr_list" "bad_ipv4_compat" {
  address = "::/96"
  list    = "bad_ipv6"
  comment = "defconf: ipv4 compat"
}

resource "routeros_ipv6_firewall_addr_list" "bad_discard" {
  address = "100::/64"
  list    = "bad_ipv6"
  comment = "defconf: discard only "
}

resource "routeros_ipv6_firewall_addr_list" "bad_documentation" {
  address = "2001:db8::/32"
  list    = "bad_ipv6"
  comment = "defconf: documentation"
}

resource "routeros_ipv6_firewall_addr_list" "bad_orchid" {
  address = "2001:10::/28"
  list    = "bad_ipv6"
  comment = "defconf: ORCHID"
}

resource "routeros_ipv6_firewall_addr_list" "bad_6bone" {
  address = "3ffe::/16"
  list    = "bad_ipv6"
  comment = "defconf: 6bone"
}

resource "routeros_ipv6_firewall_filter" "input_established" {
  action           = "accept"
  chain            = "input"
  comment          = "defconf: accept established,related,untracked"
  connection_state = "established,related,untracked"
}

resource "routeros_ipv6_firewall_filter" "input_drop_invalid" {
  action           = "drop"
  chain            = "input"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
}

resource "routeros_ipv6_firewall_filter" "input_icmpv6" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept ICMPv6"
  protocol = "icmpv6"
}

resource "routeros_ipv6_firewall_filter" "input_traceroute" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept UDP traceroute"
  dst_port = "33434-33534"
  protocol = "udp"
}

resource "routeros_ipv6_firewall_filter" "input_dhcpv6_client" {
  action      = "accept"
  chain       = "input"
  comment     = "defconf: accept DHCPv6-Client prefix delegation."
  dst_port    = "546"
  protocol    = "udp"
  src_address = "fe80::/10"
}

resource "routeros_ipv6_firewall_filter" "input_ike" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept IKE"
  dst_port = "500,4500"
  protocol = "udp"
}

resource "routeros_ipv6_firewall_filter" "input_ipsec_ah" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept ipsec AH"
  protocol = "ipsec-ah"
}

resource "routeros_ipv6_firewall_filter" "input_ipsec_esp" {
  action   = "accept"
  chain    = "input"
  comment  = "defconf: accept ipsec ESP"
  protocol = "ipsec-esp"
}

resource "routeros_ipv6_firewall_filter" "input_ipsec_policy" {
  action       = "accept"
  chain        = "input"
  comment      = "defconf: accept all that matches ipsec policy"
  ipsec_policy = "in,ipsec"
}

resource "routeros_ipv6_firewall_filter" "input_drop_not_lan" {
  action            = "drop"
  chain             = "input"
  comment           = "defconf: drop everything else not coming from LAN"
  in_interface_list = "!${var.lan_interface_list}"
}

resource "routeros_ipv6_firewall_filter" "forward_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  comment          = "defconf: fasttrack6"
  connection_state = "established,related"
}

resource "routeros_ipv6_firewall_filter" "forward_established" {
  action           = "accept"
  chain            = "forward"
  comment          = "defconf: accept established,related,untracked"
  connection_state = "established,related,untracked"
}

resource "routeros_ipv6_firewall_filter" "forward_drop_invalid" {
  action           = "drop"
  chain            = "forward"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
}

resource "routeros_ipv6_firewall_filter" "forward_drop_bad_src" {
  action           = "drop"
  chain            = "forward"
  comment          = "defconf: drop packets with bad src ipv6"
  src_address_list = "bad_ipv6"
}

resource "routeros_ipv6_firewall_filter" "forward_drop_bad_dst" {
  action           = "drop"
  chain            = "forward"
  comment          = "defconf: drop packets with bad dst ipv6"
  dst_address_list = "bad_ipv6"
}

resource "routeros_ipv6_firewall_filter" "forward_drop_hop_limit" {
  action    = "drop"
  chain     = "forward"
  comment   = "defconf: rfc4890 drop hop-limit=1"
  hop_limit = "equal:1"
  protocol  = "icmpv6"
}

resource "routeros_ipv6_firewall_filter" "forward_icmpv6" {
  action   = "accept"
  chain    = "forward"
  comment  = "defconf: accept ICMPv6"
  protocol = "icmpv6"
}

resource "routeros_ipv6_firewall_filter" "forward_hip" {
  action   = "accept"
  chain    = "forward"
  comment  = "defconf: accept HIP"
  protocol = "139"
}

resource "routeros_ipv6_firewall_filter" "forward_ike" {
  action   = "accept"
  chain    = "forward"
  comment  = "defconf: accept IKE"
  dst_port = "500,4500"
  protocol = "udp"
}

resource "routeros_ipv6_firewall_filter" "forward_ipsec_ah" {
  action   = "accept"
  chain    = "forward"
  comment  = "defconf: accept ipsec AH"
  protocol = "ipsec-ah"
}

resource "routeros_ipv6_firewall_filter" "forward_ipsec_esp" {
  action   = "accept"
  chain    = "forward"
  comment  = "defconf: accept ipsec ESP"
  protocol = "ipsec-esp"
}

resource "routeros_ipv6_firewall_filter" "forward_ipsec_policy" {
  action       = "accept"
  chain        = "forward"
  comment      = "defconf: accept all that matches ipsec policy"
  ipsec_policy = "in,ipsec"
}

resource "routeros_ipv6_firewall_filter" "forward_drop_not_lan" {
  action            = "drop"
  chain             = "forward"
  comment           = "defconf: drop everything else not coming from LAN"
  in_interface_list = "!${var.lan_interface_list}"
}
