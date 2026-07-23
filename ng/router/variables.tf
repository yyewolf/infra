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

variable "lan_interfaces" {
  description = "Ethernet interfaces to add to the LAN bridge"
  type        = list(string)
  default     = ["ether2", "ether3", "ether4", "ether5", "sfp1"]
}
