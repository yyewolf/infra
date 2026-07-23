data "sops_file" "router_credentials" {
  source_file = "${path.module}/router-sops.yaml"
}

provider "routeros" {
  hosturl        = "https://192.168.1.49"
  username       = data.sops_file.router_credentials.data["secrets.username"]
  password       = data.sops_file.router_credentials.data["secrets.password"]
  #ca_certificate = "./cert/mikrotik_ssl.crt"
  insecure       = true
}
