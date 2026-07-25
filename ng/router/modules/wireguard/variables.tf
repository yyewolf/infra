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

variable "interface_list" {
  description = "Interface list to add the WireGuard interface to, so firewall rules can treat the tunnel as inside. Null leaves it out of every list"
  type        = string
  default     = null
}

variable "persistent_keepalive" {
  description = "Keepalive interval for peers we dial, keeps the NAT mapping on our side open so the peer can reach us"
  type        = string
  default     = "25s"
}

variable "peers" {
  description = "Peers keyed by identity name"
  type = map(object({
    public_key = string
    address    = string
    endpoint   = optional(string)
    routes     = optional(list(string), [])
  }))
  default = {}
}
