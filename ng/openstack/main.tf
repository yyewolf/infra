# edge-0: the cloud Talos worker, on Infomaniak's OpenStack.
#
# This node joins the cluster over WireGuard and only over WireGuard. The tunnel
# is part of its Talos machine config rather than something configured after
# boot, so it is up before the kubelet starts and the node never reaches the
# control plane across the bare internet — not even once, during join.
#
# Consequently nothing about the cluster is defined here. The machine config,
# including the tunnel, is rendered by ng/talos/talos.sh from cluster.yaml and
# the WireGuard registry; this file only builds the box it runs on and hands it
# that config as user data. See ng/talos/README.md for the ordering.

locals {
  # Read rather than duplicated: the image has to be the same Talos version and
  # the same Image Factory schematic as the rest of the cluster, and both of
  # those already have a home.
  talos_cluster = yamldecode(file("${path.module}/../talos/cluster.yaml"))
  talos_version = local.talos_cluster.talos_version

  # Written by 'talos.sh schematic' as two lines: the hash of schematic.yaml,
  # then the ID the factory returned.
  schematic_path = "${path.module}/../talos/out/schematic-id"
  schematic_id   = fileexists(local.schematic_path) ? trimspace(split("\n", file(local.schematic_path))[1]) : ""

  # The 'openstack' platform image, not 'metal': it knows to read its config
  # from the cloud metadata service instead of expecting an installer.
  image_url = "https://factory.talos.dev/image/${local.schematic_id}/${local.talos_version}/openstack-amd64.raw.xz"

  # Rendered by 'talos.sh render edge-0'. Contains the cluster PKI and the
  # WireGuard private key, which is why ng/talos/out/ is gitignored and this
  # module's state is PGP-encrypted by tf.sh.
  machine_config_path = "${path.module}/../talos/out/${var.instance_name}.yaml"
  machine_config      = fileexists(local.machine_config_path) ? file(local.machine_config_path) : ""
}

# Only the listen port is needed here, to open it in the security group. The
# private key lives in the machine config, not in Terraform.
data "sops_file" "wg_identities" {
  source_file = "${path.module}/../wireguard/identities-sops.yaml"
}

locals {
  wg_identities  = nonsensitive(yamldecode(data.sops_file.wg_identities.raw).identities)
  wg_listen_port = local.wg_identities[var.instance_name].listen_port
}

# Infomaniak has no Neutron "external" network and therefore no floating IPs:
# nothing in this project is flagged external, so there is no pool to allocate
# from. Instances attach directly to a shared dual-stack provider network and
# the port itself holds the public addresses.
#
# In dc4-a that network is 'ext-net1' — 21 public IPv4 /24s plus one IPv6 /64
# (2001:1600:16:10::/64). There is also 'ext-v6only1' for v6-only instances.
data "openstack_networking_network_v2" "public" {
  name = var.public_network
}

# Named subnets, only used when var.v4_subnet_name / var.v6_subnet_name are set.
# Left unset by default: with 21 IPv4 pools that Infomaniak grows over time,
# letting Neutron choose is more robust than pinning to one that may fill up.
data "openstack_networking_subnet_v2" "v4" {
  count      = var.v4_subnet_name == "" ? 0 : 1
  name       = var.v4_subnet_name
  network_id = data.openstack_networking_network_v2.public.id
}

data "openstack_networking_subnet_v2" "v6" {
  count      = var.v6_subnet_name == "" ? 0 : 1
  name       = var.v6_subnet_name
  network_id = data.openstack_networking_network_v2.public.id
}

# ---------------------------------------------------------------------- image

resource "openstack_images_image_v2" "talos" {
  # Name pins both inputs so a version or schematic change uploads a new image
  # rather than silently reusing the old one.
  name             = "talos-${local.talos_version}-${substr(local.schematic_id, 0, 12)}"
  image_source_url = local.image_url
  container_format = "bare"
  disk_format      = "raw"

  # The factory only publishes the raw image xz-compressed; Glance wants it raw.
  decompress = true
  visibility = "private"

  lifecycle {
    precondition {
      condition     = local.schematic_id != ""
      error_message = "No ${local.schematic_path}. Run 'ng/talos/talos.sh schematic' first."
    }
    # Glance stamps its own properties (checksums, store locations, boot flags)
    # onto every image, which would otherwise show as permanent drift.
    ignore_changes = [properties]
  }
}

# ------------------------------------------------------------- network + rules

# This port is directly on the public internet — there is no NAT and no floating
# IP indirection in front of it. The security group is therefore the *only*
# thing standing between the internet and the node, which on a Talos worker
# means apid (50000) and the kubelet (10250). Neutron denies all ingress by
# default, so the rule set below is exhaustive: anything not listed is closed.
resource "openstack_networking_secgroup_v2" "edge" {
  name        = "${var.instance_name}-wireguard"
  description = "edge-0: WireGuard in, everything out. No SSH — Talos has no shell."
}

# The home router sits behind the ISP's NAT and has no stable endpoint, so it
# dials us and we are the responder. That makes this rule load-bearing: without
# it the tunnel can never be established from either side.
resource "openstack_networking_secgroup_rule_v2" "wireguard_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = local.wg_listen_port
  port_range_max    = local.wg_listen_port
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "WireGuard from the home router (dynamic source address)"
}

# Deliberately not opened: TCP 50000 (Talos API) and 6443 (Kubernetes API).
# Both are reachable on 10.200.255.2 through the tunnel, which is the only place
# they should be reachable from.

# The same, over IPv6. Costs nothing today — the home router has no working
# IPv6 yet, so it dials the v4 endpoint — but it means switching the endpoint
# to v6 later is a registry edit rather than a firewall change.
resource "openstack_networking_secgroup_rule_v2" "wireguard_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = local.wg_listen_port
  port_range_max    = local.wg_listen_port
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "WireGuard over IPv6, for when ng/router terminates v6"
}

resource "openstack_networking_secgroup_rule_v2" "icmp_v4" {
  count = var.allow_icmp ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Ping, for checking the box is alive when the tunnel is not"
}

# ICMPv6 is not optional the way ICMPv4 is. Dropping it breaks path MTU
# discovery and neighbour discovery, which fails as intermittent hangs on large
# responses rather than as anything that looks like a firewall problem.
resource "openstack_networking_secgroup_rule_v2" "icmp_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "ICMPv6: NDP and PMTUD, required for working IPv6"
}

# Envoy Gateway terminates HTTP, HTTPS, and QUIC/HTTP3 on edge-0's public
# IPs. The proxy listens on externalIPs set via EnvoyProxy, so the traffic
# lands directly on the VM's NIC. Opens both families: dual-stack services
# that bind a v6 address are unreachable without this.
resource "openstack_networking_secgroup_rule_v2" "http_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway HTTP"
}

resource "openstack_networking_secgroup_rule_v2" "https_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway HTTPS"
}

resource "openstack_networking_secgroup_rule_v2" "quic_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway QUIC/HTTP3"
}

resource "openstack_networking_secgroup_rule_v2" "http_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway HTTP over IPv6"
}

resource "openstack_networking_secgroup_rule_v2" "https_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway HTTPS over IPv6"
}

resource "openstack_networking_secgroup_rule_v2" "quic_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway QUIC/HTTP3 over IPv6"
}

# Port 22 reaches the `portfoliosh` TUI through a TCP listener on the same
# Gateway, never a host sshd — Talos runs none, so nothing else on edge-0 is
# listening here. The listener exists only while that app's ListenerSet does;
# these rules are the other half, and without them the port is closed at
# Neutron no matter what the Gateway says.
resource "openstack_networking_secgroup_rule_v2" "ssh_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway TCP for portfoliosh"
}

resource "openstack_networking_secgroup_rule_v2" "ssh_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.edge.id
  description       = "Envoy Gateway TCP for portfoliosh over IPv6"
}

# An explicit port rather than letting Nova create one, so the addresses are a
# first-class output and the security group is attached before the instance
# ever boots.
#
# It also breaks a chicken-and-egg: the router needs edge-0's public address as
# the WireGuard endpoint, but that address does not exist until Terraform
# creates something. Create just the port first — see ng/talos/README.md:
#
#     ./ng/openstack/tf.sh apply -target=openstack_networking_port_v2.edge
resource "openstack_networking_port_v2" "edge" {
  name               = var.instance_name
  network_id         = data.openstack_networking_network_v2.public.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.edge.id]

  # Neutron's default allocation (no fixed_ip blocks at all) takes one address
  # from each subnet it can, which on this network means a public v4 and a
  # public v6. Pin them only if that picks badly — and note it is both or
  # neither: naming one subnet stops Neutron auto-allocating the other.
  dynamic "fixed_ip" {
    for_each = data.openstack_networking_subnet_v2.v4
    content {
      subnet_id = fixed_ip.value.id
    }
  }

  dynamic "fixed_ip" {
    for_each = data.openstack_networking_subnet_v2.v6
    content {
      subnet_id = fixed_ip.value.id
    }
  }
}

locals {
  # all_fixed_ips mixes families; split them so the outputs are usable.
  port_v4 = [for ip in openstack_networking_port_v2.edge.all_fixed_ips : ip if !strcontains(ip, ":")]
  port_v6 = [for ip in openstack_networking_port_v2.edge.all_fixed_ips : ip if strcontains(ip, ":")]
}

# --------------------------------------------------------------------- compute

resource "openstack_compute_instance_v2" "edge" {
  name        = var.instance_name
  image_id    = openstack_images_image_v2.talos.id
  flavor_name = var.flavor_name

  # Talos reads this on every boot, so it is the whole node definition and not
  # just a first-boot script. Changing it here replaces the instance; to change
  # a running node use 'talosctl apply-config' over the tunnel instead.
  user_data = local.machine_config

  # Belt and braces: the Talos openstack platform tries the metadata service
  # first and falls back to a config drive. A node that finds neither sits in
  # maintenance mode forever, unreachable, with no console worth the name.
  config_drive = true

  network {
    port = openstack_networking_port_v2.edge.id
  }

  lifecycle {
    precondition {
      condition     = local.machine_config != ""
      error_message = "No ${local.machine_config_path}. Run 'ng/talos/talos.sh render ${var.instance_name}' first."
    }
  }
}

# --------------------------------------------------------------------- outputs
#
# No floating IPs anywhere in this module, and none are possible: floating IPs
# are allocated from a Neutron network flagged external, and this project has
# none. They are also an IPv4 NAT construct with no IPv6 equivalent, so a "v6
# floating IP" is not a thing on any OpenStack. The public addresses here come
# straight off the port instead, which gives edge-0 real public v4 *and* v6
# rather than a NATted v4 — strictly better than what a floating IP would have.

output "instance_name" {
  value = openstack_compute_instance_v2.edge.name
}

output "public_v4" {
  description = "Public IPv4 on the port. Record this as edge-0's endpoint in ng/wireguard/identities-sops.yaml so the router can dial it."
  value       = try(local.port_v4[0], null)
}

output "public_v6" {
  description = "Public IPv6 on the port. Ingress only — deliberately not edge-0's Kubernetes node address; see ng/talos/README.md."
  value       = try(local.port_v6[0], null)
}

output "wireguard_endpoint" {
  description = "Ready to paste into gen-identity.sh"
  value       = try("${local.port_v4[0]}:${local.wg_listen_port}", null)
}

output "node_address" {
  description = "edge-0's cluster address, reachable only through the tunnel"
  value       = local.talos_cluster.nodes[var.instance_name].address
}
