variable "wan_interface" {
  description = "WAN interface name"
  type        = string
  default     = "ether1"
}

variable "wan_hostname" {
  description = "Hostname sent to ISP via DHCP"
  type        = string
  default     = "mikrotik-router"
}

variable "lan_interface_list" {
  description = "Interface list name for LAN interfaces"
  type        = string
  default     = "LAN"
}

variable "wan_interface_list" {
  description = "Interface list name for WAN interfaces"
  type        = string
  default     = "WAN"
}

variable "lan_blocked_destinations" {
  description = "Subnets LAN clients must not reach through the router, the upstream network sitting behind the WAN interface"
  type        = list(string)
  default     = []
}

variable "lan_subnet" {
  description = "LAN subnet in CIDR notation, the first address is the router itself. Must not overlap the WireGuard range (10.200.255.0/24)"
  type        = string
  default     = "10.200.0.0/24"
}

variable "lan_dhcp_pool_ranges" {
  description = "Address ranges handed out by the LAN DHCP server, .2-.99 is left free for static assignments"
  type        = list(string)
  default     = ["10.200.0.100-10.200.0.254"]
}

variable "lan_dhcp_lease_time" {
  description = "LAN DHCP lease duration"
  type        = string
  default     = "1h"
}

variable "lan_interfaces" {
  description = "Ethernet interfaces to add to the LAN bridge"
  type        = list(string)
  default     = ["ether2", "ether3", "ether4", "ether5", "sfp1"]
}

# Services on the LAN reachable from the upstream network. The cluster sits on
# 10.200.0.0/24 behind this router and the upstream network has no route to it,
# so a host on 192.168.1.0/24 cannot address a node directly no matter what the
# firewall says — the packet has nowhere to go. A destination NAT on the router
# is what bridges that, and it also satisfies `forward_drop_wan_new`, which
# drops new inbound-from-WAN connections unless they are DSTNATed.
#
# `source` is what keeps this off the public internet. The WAN interface here
# faces the home LAN, not the internet — anything from outside would have to be
# forwarded again by the upstream router at 192.168.1.1 to arrive at all — but
# pinning the source range means that even if someone forwards a port up there
# later, this rule still only answers the local segment.
#
# Matched on the WAN interface list rather than a `dst_address`, because the
# router takes its WAN address by DHCP and 192.168.1.49 is a lease, not a
# fixture.
variable "wan_port_forwards" {
  description = "Destination NAT entries making a LAN service reachable from the upstream network. Keyed by service name."
  type = map(object({
    protocol   = string
    port       = number
    source     = string
    to_address = string
    to_port    = number
  }))
  default = {
    # The wall-mounted smart clock display lives on the upstream segment and
    # loads its page from the cluster. 30080 is the `smartclock` Service's
    # NodePort and 10.200.0.14 is w-1, the node its StatefulSet is pinned to.
    smartclock = {
      protocol   = "tcp"
      port       = 8080
      source     = "192.168.1.0/24"
      to_address = "10.200.0.14"
      to_port    = 30080
    }
  }
}

# The account Home Assistant authenticates as to ask the router to send a
# Wake-on-LAN magic packet. See the resources in main.tf for why HA asks the
# router rather than sending the packet itself.
#
# The password is deliberately not here. It lives under `secrets.wol_password`
# in router-sops.yaml, and the same value has to exist in the cluster's
# flux/apps/home-assistant/router-wol-secret-sops.yaml for HA to authenticate.
#
# Set to null to remove the user and its group.
variable "wol_user" {
  description = "RouterOS account Home Assistant authenticates as to call /tool wol."
  type = object({
    name           = string
    allowed_source = string
  })
  default = {
    name = "ha-wol"
    # w-1. Home Assistant is host-networked and pinned there, so it reaches the
    # router as the node's own address; RouterOS refuses this login from
    # anywhere else, so a leaked credential is not usable off that node.
    allowed_source = "10.200.0.14"
  }
}
