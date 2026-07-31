terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

# Rule order is the whole meaning of a firewall, but RouterOS appends new rules
# to the end of the table and Terraform creates unrelated resources in whatever
# order it likes. So every rule below pins itself with place_before pointing at
# the rule that must follow it. That makes each rule depend on its successor,
# Terraform builds the table back to front, and the resulting order is the
# order these blocks are written in.
#
# Adding a rule means splicing it into the chain: point the rule above it at
# the new rule, and the new rule at whatever used to follow. A rule with no
# place_before is the last one in the table.

# ---------------------------------------------------------------- input chain

resource "routeros_ip_firewall_filter" "input_established" {
  action           = "accept"
  chain            = "input"
  comment          = "defconf: accept established,related,untracked"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.input_drop_invalid.id
}

resource "routeros_ip_firewall_filter" "input_drop_invalid" {
  action           = "drop"
  chain            = "input"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
  place_before     = routeros_ip_firewall_filter.input_icmp.id
}

resource "routeros_ip_firewall_filter" "input_icmp" {
  action       = "accept"
  chain        = "input"
  comment      = "defconf: accept ICMP"
  protocol     = "icmp"
  place_before = routeros_ip_firewall_filter.input_loopback.id
}

resource "routeros_ip_firewall_filter" "input_loopback" {
  action       = "accept"
  chain        = "input"
  comment      = "defconf: accept to local loopback (for CAPsMAN)"
  dst_address  = "127.0.0.1"
  place_before = routeros_ip_firewall_filter.input_services.id
}

resource "routeros_ip_firewall_filter" "input_services" {
  action       = "accept"
  chain        = "input"
  dst_port     = join(",", var.input_allowed_ports)
  protocol     = "tcp"
  place_before = routeros_ip_firewall_filter.input_wireguard.id
}

resource "routeros_ip_firewall_filter" "input_wireguard" {
  action       = "accept"
  chain        = "input"
  comment      = "defconf: accept WireGuard"
  dst_port     = tostring(var.wireguard_port)
  protocol     = "udp"
  place_before = routeros_ip_firewall_filter.input_drop_not_lan.id
}

resource "routeros_ip_firewall_filter" "input_drop_not_lan" {
  action            = "drop"
  chain             = "input"
  comment           = "defconf: drop all not coming from LAN"
  in_interface_list = "!${var.lan_interface_list}"
  place_before      = routeros_ip_firewall_filter.forward_ipsec_in.id
}

# -------------------------------------------------------------- forward chain

# Anchored on forward_ipsec_in like input_drop_not_lan is, because place_before
# takes a single id and this block expands to any number of rules. That leaves
# their position relative to input_drop_not_lan unpinned, which is harmless:
# they sit in different chains and never see the same packet.
resource "routeros_ip_firewall_filter" "forward_drop_blocked_destinations" {
  for_each = toset(var.blocked_lan_destinations)

  action            = "drop"
  chain             = "forward"
  comment           = "drop LAN traffic to ${each.key}"
  connection_state  = "new"
  dst_address       = each.key
  in_interface_list = var.lan_interface_list
  place_before      = routeros_ip_firewall_filter.forward_ipsec_in.id
}

resource "routeros_ip_firewall_filter" "forward_ipsec_in" {
  action       = "accept"
  chain        = "forward"
  comment      = "defconf: accept in ipsec policy"
  ipsec_policy = "in,ipsec"
  place_before = routeros_ip_firewall_filter.forward_ipsec_out.id
}

resource "routeros_ip_firewall_filter" "forward_ipsec_out" {
  action       = "accept"
  chain        = "forward"
  comment      = "defconf: accept out ipsec policy"
  ipsec_policy = "out,ipsec"
  place_before = routeros_ip_firewall_filter.forward_fasttrack.id
}

resource "routeros_ip_firewall_filter" "forward_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  comment          = "defconf: fasttrack"
  connection_state = "established,related"
  place_before     = routeros_ip_firewall_filter.forward_established.id
}

resource "routeros_ip_firewall_filter" "forward_established" {
  action           = "accept"
  chain            = "forward"
  comment          = "defconf: accept established,related, untracked"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.forward_drop_invalid.id
}

resource "routeros_ip_firewall_filter" "forward_drop_invalid" {
  action           = "drop"
  chain            = "forward"
  comment          = "defconf: drop invalid"
  connection_state = "invalid"
  place_before     = routeros_ip_firewall_filter.forward_drop_wan_new.id
}

resource "routeros_ip_firewall_filter" "forward_drop_wan_new" {
  action               = "drop"
  chain                = "forward"
  comment              = "defconf: drop all from WAN not DSTNATed"
  connection_nat_state = "!dstnat"
  connection_state     = "new"
  in_interface_list    = var.wan_interface_list
}

# ------------------------------------------------------------------------ nat

# Reaching a LAN service from the upstream network. No matching filter rule is
# needed: forward_drop_wan_new drops new inbound-from-WAN connections only when
# `connection_nat_state` is not dstnat, so these are already let through, and
# the chain has no other drop that applies. Adding an accept here would be
# decoration.
#
# Replies do not need a srcnat counterpart either. The router is the gateway for
# the LAN subnet, so the return path comes back through it and conntrack undoes
# the translation; srcnat_masquerade below only fires for connections opened
# from the LAN side.
resource "routeros_ip_firewall_nat" "dstnat_port_forwards" {
  for_each = var.wan_port_forwards

  action            = "dst-nat"
  chain             = "dstnat"
  comment           = "${each.key}: ${each.value.source} -> ${each.value.to_address}:${each.value.to_port}"
  in_interface_list = var.wan_interface_list
  protocol          = each.value.protocol
  dst_port          = tostring(each.value.port)
  src_address       = each.value.source
  to_addresses      = each.value.to_address
  to_ports          = tostring(each.value.to_port)
}

resource "routeros_ip_firewall_nat" "srcnat_masquerade" {
  action             = "masquerade"
  chain              = "srcnat"
  comment            = "defconf: masquerade"
  ipsec_policy       = "out,none"
  out_interface_list = var.wan_interface_list
}
