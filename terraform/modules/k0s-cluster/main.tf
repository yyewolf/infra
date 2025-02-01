locals {
  k0s_hosts = [for host in var.hosts : {
    role = host.role
    ssh = {
      address       = host.floating_ip_address
      port          = 22
      user          = var.ssh_login_name
      key_path      = var.private_key_pair_path
    }
  }]

  controler_ips = [for host in var.hosts : "\"${host.floating_ip_address}\", \"${host.private_ip_address}\"" if host.role == "controller"]
}

resource "k0s_cluster" "this" {
  name    = "k0s.cluster"
  version = "1.29.6+k0s.0"

  hosts = local.k0s_hosts

  config = <<EOT
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    sans: [${join(", ", local.controler_ips)}, "127.0.0.1"]
  network:
    podCIDR: 10.244.0.0/16
    serviceCIDR: 10.96.0.0/12
    provider: calico
    calico:
      mode: vxlan
      vxlanPort: 4789
      vxlanVNI: 4096
      mtu: 1450
      wireguard: false
      flexVolumeDriverPath: /usr/libexec/k0s/kubelet-plugins/volume/exec/nodeagent~uds
      withWindowsNodes: false
      overlay: Always
  images:
    calico:
      cni:
        image: calico/cni
        version: v3.16.2
      flexvolume:
        image: calico/pod2daemon-flexvol
        version: v3.16.2
      node:
        image: calico/node
        version: v3.16.2
      kubecontrollers:
        image: calico/kube-controllers
        version: v3.16.2
EOT
}

# We can now output the kubeconfig
resource "local_file" "kubeconfig" {
    content  = k0s_cluster.this.kubeconfig
    filename = "output/kubeconfig"
}