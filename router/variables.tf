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

# Wake-on-LAN across the WAN boundary. Home Assistant runs host-networked on
# w-1, which has one NIC on the LAN and no leg on the upstream network, so a
# magic packet aimed at the upstream broadcast address leaves w-1 as an
# ordinary routed packet. Routers drop directed broadcasts by default
# (RFC 2644) and RouterOS is no exception, so without the static ARP entry in
# main.tf the packet dies here and the target never wakes.
#
# `allowed_sources` is not decoration. The ARP entry turns the upstream
# broadcast address into something any LAN host can reach, which is a standing
# amplification and host-discovery surface; the firewall rule in the ip-firewall
# module narrows it back down to the machines that actually need it. Widening
# this list widens that surface — it is not a list to grow casually.
#
# Set to null to remove the ARP entry, the address list and the guard rule
# together.
variable "wol_relay" {
  description = "Relay directed broadcasts to the upstream network so LAN hosts can send Wake-on-LAN magic packets to it. The interface is always the WAN interface, since that is the segment the upstream broadcast address belongs to."
  type = object({
    address         = string
    allowed_sources = list(string)
  })
  default = {
    # Broadcast address of the upstream network on the far side of the WAN
    # interface, where the router itself holds 192.168.1.49.
    address = "192.168.1.255"
    # w-1, the node Home Assistant is pinned to. It is host-networked, so the
    # magic packet leaves with the node's own address as its source.
    allowed_sources = ["10.200.0.14"]
  }
}
