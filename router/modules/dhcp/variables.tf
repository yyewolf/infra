variable "name" {
  description = "Name of the DHCP server and its address pool"
  type        = string
  default     = "lan-dhcp"
}

variable "interface" {
  description = "Interface the DHCP server listens on"
  type        = string
}

variable "subnet" {
  description = "Subnet served by the DHCP server, in CIDR notation"
  type        = string
}

variable "gateway" {
  description = "Gateway handed out to clients"
  type        = string
}

variable "pool_ranges" {
  description = "Address ranges handed out to clients"
  type        = list(string)
}

variable "dns_servers" {
  description = "DNS servers handed out to clients"
  type        = list(string)
}

variable "domain" {
  description = "Domain handed out to clients"
  type        = string
  default     = null
}

variable "lease_time" {
  description = "DHCP lease duration"
  type        = string
  default     = "10m"
}
