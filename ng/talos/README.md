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
cluster.yaml            addressing, versions, node inventory, per-node extensions
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

## System extensions

`schematic.yaml` is the image every node shares — microcode, iSCSI tools. A
node can also carry extras of its own, listed under `extensions:` in its
`cluster.yaml` entry:

```yaml
cp-0:
  type: controlplane
  address: 10.200.0.11
  address6: fdde:c64:7096::11
  extensions:
    - siderolabs/kata-containers
```

`render` merges those into `schematic.yaml`, resolves the result to its own
Image Factory ID (cached in `out/schematics/<node>.id`) and points only that
node's `machine.install.image` at it. Nodes without extras keep the base ID, so
adding an extension to one host does not re-image the others.

Off-LAN nodes are excluded on purpose: `ng/openstack` builds `edge-0`'s Glance
image from `out/schematic-id`, the *base* ID, so an extension listed on
`edge-0` would have it install an image it never booted from. `render` refuses
rather than let that through — extensions that node needs go in
`schematic.yaml`.

### Kata Containers

`cp-0`, `cp-1` and `cp-2` carry `siderolabs/kata-containers`. Pods that ask for
it run under a lightweight VM with their own kernel instead of sharing the
host's. The extension registers the containerd runtime handlers itself; the
`RuntimeClass` objects that expose them come from Flux
(`ng/flux/infrastructure/kata`), one per hypervisor:

| class | hypervisor | when |
|---|---|---|
| `kata` | Cloud Hypervisor | the default: fast boot, low overhead |
| `kata-qemu` | QEMU | passes the CPU virt flag through, so the guest can run VMs |

```yaml
spec:
  runtimeClassName: kata
```

Both classes carry a `nodeSelector` for `node-role.kubernetes.io/control-plane`,
which on this cluster means the three LAN hosts. `edge-0` is a cloud instance
with no nested virtualization and does not have the extension, so without that
selector a kata pod could be scheduled there and fail at the kubelet with an
unknown runtime handler.

KVM needs no configuration — Talos builds `kvm`, `kvm_amd` and `kvm_intel` into
the kernel rather than shipping them as modules.

### gVisor

`cp-2` also carries `siderolabs/gvisor`. Where kata gives a pod its own kernel
in a VM, gVisor gives it a userspace kernel — the sentry — which intercepts
syscalls in a normal host process. Cheaper than a VM, a narrower syscall surface
than runc, and no virtualization needed.

Unlike kata it is not extension-only. It needs machine config too, which is what
the per-node `patches:` key in `cluster.yaml` delivers:

```yaml
cp-2:
  extensions:
    - siderolabs/gvisor
  patches:
    - gvisor.yaml
```

`patches/gvisor.yaml` does two things. It raises `user.max_user_namespaces` —
Talos ships it at 0 per the KSPP recommendation and every runsc container fails
to start without it, which is why the sysctl is scoped to this node rather than
put in `common.yaml`. And it registers a `runsc-netraw` containerd handler
running stock runsc with two flags:

| flag | why |
|---|---|
| `--net-raw` | without it runsc strips `CAP_NET_RAW`, so ping, dhclient and dockerd get `EPERM` |
| `--allow-packet-socket-write` | Docker 28+ sends unsolicited ARP/NA when bringing an interface up |

Both let the sandbox craft arbitrary packets onto the pod network. That is a
real weakening of gVisor's *network* isolation — the syscall boundary is
untouched — so the extension's own flagless `runsc` handler is left registered
and unused rather than overridden. The `gvisor` RuntimeClass
(`ng/flux/infrastructure/gvisor`) points at `runsc-netraw` and pins scheduling
to `cp-2` by hostname, since it is the only node with the extension.

```yaml
spec:
  runtimeClassName: gvisor
```

Two Talos rules constrain how that config is written, and both fail *hard* —
`writeUserFiles` aborts the boot sequence before the kubelet starts, leaving the
node up on `apid` but `NotReady` with `/etc/kubernetes` read-only:

- **`machine.files` may only `create` under `/var`.** Anywhere else needs
  `overwrite` or `append` on a file that already exists. That is why the runsc
  config lives at `/var/cri/conf.d/runsc-netraw.toml`.
- **There is exactly one CRI drop-in path**, `/etc/cri/conf.d/20-customization.part`.
  Talos special-cases it and injects the content as a config patch; any other
  name under that directory falls through to the file writer and hits the rule
  above. All CRI customization for a node shares that one file.

Recovery, if it happens anyway: the node still answers `talosctl`, so fix the
config and `./talos.sh apply <node>` — no console needed.

## Upgrades

Bump `talos_version` in `cluster.yaml`, then `./talos.sh render`. The installer
image in each config now points at the new version, and:

```sh
./talos.sh upgrade cp-0        # then cp-1, then cp-2
```

reboots each node onto it. One at a time: with three control-plane nodes, etcd
tolerates exactly one being away.

Changing the extension list — `schematic.yaml` or a node's `extensions:` —
works the same way. It is a new schematic ID and a new installer image, and
`apply` alone will not deliver it: `machine.install.image` only decides what the
*next* install writes, so an extension added to a running node needs the
upgrade.

## Notes

- `talosctl validate --config out/<node>.yaml --mode metal` checks a rendered
  config before you apply it.
- `out/` is `chmod 700` and the rendered configs `0600`: they contain the
  decrypted cluster PKI.
- The Image Factory is a public, content-addressed build service. Uploading
  `schematic.yaml` publishes only the extension list, no secrets, and an
  unchanged file always resolves to the same ID.
