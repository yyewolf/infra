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
  default     = ["192.168.1.0/24"]
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
