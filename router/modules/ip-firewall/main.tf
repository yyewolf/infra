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

# The other half of the WoL relay. The root module's ARP entry makes the
# upstream broadcast address resolvable, which by itself lets any LAN host
# broadcast onto the upstream segment — this drops that traffic from everything
# except the named sources.
#
# Negating an address list rather than `src_address = "!x.x.x.x"` so more than
# one source can be permitted without the rule turning into a pile of rules.
#
# Anchored on forward_ipsec_in for the same reason the blocked-destinations
# rules below are, and it must stay ahead of the fasttrack and established
# rules: fasttrack in particular would let an already-seen flow bypass this
# entirely. Everything from here to forward_drop_wan_new is drops and accepts
# for traffic this rule has already had its say on.
resource "routeros_ip_firewall_addr_list" "directed_broadcast_sources" {
  for_each = toset(try(var.directed_broadcast_relay.allowed_sources, []))

  address = each.key
  list    = "wol-relay-sources"
  comment = "may broadcast to ${var.directed_broadcast_relay.address}"
}

resource "routeros_ip_firewall_filter" "forward_drop_directed_broadcast" {
  count = var.directed_broadcast_relay == null ? 0 : 1

  action           = "drop"
  chain            = "forward"
  comment          = "drop directed broadcasts to ${var.directed_broadcast_relay.address} except from wol-relay-sources"
  dst_address      = var.directed_broadcast_relay.address
  src_address_list = "!wol-relay-sources"
  place_before     = routeros_ip_firewall_filter.forward_ipsec_in.id

  # The list has to exist before a rule can reference it, and Terraform cannot
  # see that dependency through a string literal.
  depends_on = [routeros_ip_firewall_addr_list.directed_broadcast_sources]
}

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

resource "routeros_ip_firewall_nat" "srcnat_masquerade" {
  action             = "masquerade"
  chain              = "srcnat"
  comment            = "defconf: masquerade"
  ipsec_policy       = "out,none"
  out_interface_list = var.wan_interface_list
}
