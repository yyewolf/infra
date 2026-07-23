variable "input_allowed_ports" {
  description = "TCP ports to accept on the router's input chain (Winbox, HTTPS, etc.)"
  type        = list(string)
  default     = ["8729", "443"]
}

variable "wireguard_port" {
  description = "UDP port for WireGuard incoming traffic"
  type        = number
  default     = 51820
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
