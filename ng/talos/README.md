# ng/talos — Talos cluster definition

Three physical hosts behind the MikroTik router, all control-plane with
scheduling enabled. A cloud worker joins later over the router's WireGuard
tunnel.

Everything here is declarative: `cluster.yaml` holds the addressing,
`schematic.yaml` defines the image, `patches/` holds the config every node or
every role shares, `nodes/` holds hardware facts. `talos.sh` turns those into
machine configs. Nothing generated is committed — `out/` is gitignored and can
be deleted and rebuilt at any time from git plus `secrets-sops-all.yaml`.

## Layout

```
cluster.yaml            addressing, versions, node inventory — the source of truth
schematic.yaml          Image Factory schematic (system extensions, kernel args)
secrets-sops-all.yaml   cluster PKI and tokens, SOPS-encrypted (generated once)
patches/common.yaml     applied to every node
patches/controlplane.yaml
patches/worker.yaml
nodes/<name>.yaml       hardware facts only (install disk)
talos.sh                the driver
out/                    generated, gitignored, contains plaintext PKI
```

Addressing lives in `cluster.yaml` and nowhere else. `talos.sh render` derives
each node's hostname, static address, route, VIP, cert SANs and kubelet node IP
from it, so there is no second place to keep in sync.

| | |
|---|---|
| LAN | `10.200.0.0/24`, gateway `10.200.0.1` (see `ng/router`) |
| Control-plane VIP | `10.200.0.10` |
| Nodes | `cp-0` `.11`, `cp-1` `.12`, `cp-2` `.13` |
| WireGuard overlay | `10.200.255.0/24` — `edge-0` is `.2` |

Node addresses sit below the router's DHCP pool (`.100-.254`), so static
addressing and DHCP cannot collide.

## Bring-up

### 1. Write the USB key

One key serves all three hosts. The ISO boots into maintenance mode and never
touches local storage, so you carry the same key from box to box and the real
install happens over the network in step 4.

```sh
cd ng/talos
./talos.sh usb /dev/sdX        # prompts before erasing anything
```

### 2. Generate the cluster PKI

Once, ever. Regenerating orphans an existing cluster.

```sh
./talos.sh secrets             # writes secrets-sops-all.yaml, commit it
```

The file is named `-sops-all` so the repo's `.sops.yaml` encrypts *every* value.
The plain `-sops` rule only covers keys called `secrets`, which would leave the
CA private keys in git as plaintext.

### 3. Find each node's install disk

Boot a host from the key. It comes up in maintenance mode with a DHCP address
from the router — find it in the lease table (`/ip dhcp-server lease print`),
then:

```sh
./talos.sh disks 10.200.0.137
```

Put the real device into `nodes/<name>.yaml`. It has to be explicit: a
size-based selector would happily match the USB installer, and picking wrong
wipes the wrong disk. `render` refuses while any node still says `REPLACE_ME`.

If a host has more than one physical NIC, also set `interface:` for it in
`cluster.yaml` — otherwise the config matches "the physical interface" and Talos
would put the same address on both.

### 4. Render and apply

```sh
./talos.sh render
./talos.sh apply cp-0 10.200.0.137    # maintenance IP, first time only
```

The node installs to disk, reboots onto its static address, and from then on
`./talos.sh apply cp-0` (no IP) reaches it over PKI. Repeat for `cp-1` and
`cp-2`.

### 5. Bootstrap etcd

Once, on one node only. Running it twice, or on a second node, forks the
cluster.

```sh
./talos.sh bootstrap
```

### 6. Kubeconfig

```sh
./talos.sh kubeconfig
export KUBECONFIG=$(pwd)/out/kubeconfig
```

Every node stays `NotReady` until a CNI is installed — that is expected.
`patches/controlplane.yaml` sets `cni: none` and disables kube-proxy because
Cilium replaces both.

## The cloud worker (edge-0)

`edge-0` runs on Infomaniak's OpenStack (`ng/openstack`) and is the one node not
on the LAN. Its physical NIC takes a DHCP lease from the cloud and exists only
to carry a WireGuard tunnel; its cluster address, `10.200.255.2`, lives on `wg0`.

The tunnel is part of the machine config, not something configured after boot.
Talos brings the network up from that config before starting the kubelet, so the
node reaches the API server through the tunnel on its very first attempt and
never talks to the control plane over the bare internet — not even during join.

`talos.sh render` builds the `wg0` interface from
`ng/wireguard/identities-sops.yaml`, the same registry `ng/router` builds its
peers from, and refuses to render if the address there disagrees with
`cluster.yaml`. The two ends cannot drift.

### Ordering

The home router is behind the ISP's NAT, so it dials `edge-0` rather than the
other way round — which means the router needs `edge-0`'s public address before
`edge-0` can be built with it. Create the port on its own first:

```sh
./ng/openstack/tf.sh apply -target=openstack_networking_port_v2.edge
./ng/openstack/tf.sh output wireguard_endpoint      # e.g. 83.228.230.x:51820
```

Then record it against the identity, regenerating the keypair in place:

```sh
./ng/wireguard/gen-identity.sh edge-0 10.200.255.2/32 51820 195.15.x.y:51820
```

Do this *before* rendering — `gen-identity.sh` mints a new keypair every run, so
a config rendered earlier would carry a private key the router no longer knows.

Now render, teach the router about the peer, and build the box:

```sh
cd ng/talos && ./talos.sh schematic && ./talos.sh render edge-0
./ng/router/tf.sh apply          # picks up the new peer + route automatically
./ng/openstack/tf.sh apply
```

The router's WireGuard module derives peers from every identity in the registry
except its own, so there is nothing to edit there.

`edge-0` should appear in `kubectl get nodes` a couple of minutes after the
instance boots. If it does not, the tunnel is the thing to check first — from
the router, `/interface wireguard peers print` shows the last handshake.

### Limitations

- **Dual-stack on the outside, IPv4 only on the inside.** Infomaniak's
  `ext-net1` is dual-stack, so the cloud NIC gets a public IPv6 as well as a
  public IPv4 (`dhcp6: true` in `cluster.yaml` — the subnet is
  `dhcpv6-stateful`, so it has to be asked for). That v6 is for **ingress
  only**. It is deliberately not `edge-0`'s Kubernetes address: the kubelet is
  pinned to the WireGuard overlay, and a node registered under its public v6
  would have the other three reaching it across the open internet instead of
  the tunnel.

  In-cluster, `edge-0` is therefore still v4-only and will not back IPv6
  Services. Fixing that means giving the *overlay* a v6 ULA and setting
  `address6` here — not reusing the public address.

  Pods on `edge-0` can still serve IPv6 traffic from other nodes: VXLAN carries
  v6 pod traffic inside v4 outer packets, so the v4-only tunnel is not a
  barrier to that.
- **MTU is coupled to Cilium.** `network.wg_mtu` (1420) is the number
  `ng/cluster/cilium/values.yaml` sets as its underlay MTU. Pod traffic to this
  node is built for it: pod payload 1370 + VXLAN 50 = 1420, exactly filling the
  tunnel. Change one without the other and cross-node traffic to the edge drops
  silently at full size while ping keeps working.
- **Replacing the instance replaces the node.** `user_data` is the machine
  config, so editing it in Terraform destroys and recreates the VM. To change a
  running `edge-0`, re-render and `talosctl apply-config` over the tunnel.

## Upgrades

Bump `talos_version` in `cluster.yaml`, then `./talos.sh render`. The installer
image in each config now points at the new version; `talosctl upgrade` per node
picks it up. Changing `schematic.yaml` (adding a system extension, say) works
the same way — a new schematic ID, a new installer image, one upgrade per node.

## Notes

- `talosctl validate --config out/<node>.yaml --mode metal` checks a rendered
  config before you apply it.
- `out/` is `chmod 700` and the rendered configs `0600`: they contain the
  decrypted cluster PKI.
- The Image Factory is a public, content-addressed build service. Uploading
  `schematic.yaml` publishes only the extension list, no secrets, and an
  unchanged file always resolves to the same ID.
