variable "openstack_cloud" {
  description = "clouds.yaml entry name. Infomaniak names these <project>-<region>; the project has one entry per datacentre"
  type        = string
  default     = "PCP-SESBZOV-dc4-a"
}

variable "instance_name" {
  description = "Instance hostname. Must match a node in talos/cluster.yaml and an identity in wireguard/identities-sops.yaml — this module looks itself up in both by this name"
  type        = string
  default     = "edge-0"
}

variable "flavor_name" {
  description = "OpenStack flavor. Talos wants 2 GB of RAM minimum for a worker; the disk must be at least as large as the image"
  type        = string
  default     = "a2-ram4-disk50-perf1"
}

variable "public_network" {
  description = "Shared provider network the instance attaches to. Infomaniak has no Neutron external network and no floating IPs — the port carries the public addresses directly. 'ext-net1' is dual-stack; 'ext-v6only1' is IPv6 only"
  type        = string
  default     = "ext-net1"
}

variable "v4_subnet_name" {
  description = "Pin the IPv4 address to a named subnet instead of letting Neutron choose. Empty means auto. Setting either this or v6_subnet_name disables auto-allocation for BOTH families, so set both or neither"
  type        = string
  default     = ""
}

variable "v6_subnet_name" {
  description = "Pin the IPv6 address to a named subnet. See v4_subnet_name — set both or neither. On ext-net1 the only choice is 'ext-net1-v6subnet1' (2001:1600:16:10::/64, dhcpv6-stateful)"
  type        = string
  default     = ""
}

variable "allow_icmp" {
  description = "Allow inbound ping on the public address. Useful for telling 'the box is down' apart from 'the tunnel is down', since Talos offers nothing else to probe from outside"
  type        = bool
  default     = true
}
