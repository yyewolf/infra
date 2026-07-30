output "interface" {
  description = "WAN interface in use"
  value       = routeros_ip_dhcp_client.wan.interface
}

output "address" {
  description = "IP address obtained via DHCP"
  value       = routeros_ip_dhcp_client.wan.address
}
