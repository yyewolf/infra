variable "interface_name" {
  description = "WAN interface name (e.g. ether1, sfp-sfpplus1)"
  type        = string
  default     = "ether1"
}

variable "hostname" {
  description = "Hostname sent to the ISP via DHCP"
  type        = string
  default     = "mikrotik-router"
}
