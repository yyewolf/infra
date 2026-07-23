variable "interface_name" {
  description = "WireGuard interface name"
  type        = string
}

variable "comment" {
  description = "Interface and address comment"
  type        = string
  default     = ""
}

variable "private_key" {
  description = "Private key for this node"
  type        = string
  sensitive   = true
}

variable "listen_port" {
  description = "UDP listen port"
  type        = number
}

variable "interface_address" {
  description = "IP address to assign to the WireGuard interface"
  type        = string
}

variable "lan_subnet" {
  description = "Optional LAN subnet to include in each peer's allowed_address"
  type        = string
  default     = null
}

variable "peers" {
  description = "Peers keyed by identity name"
  type = map(object({
    public_key = string
    address    = string
    endpoint   = optional(string)
  }))
  default = {}
}
