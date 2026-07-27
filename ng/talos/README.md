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
out/installer/          pushed digests of locally built installer images
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

`cp-0`, `cp-1` and `cp-2` also carry `siderolabs/gvisor`. Where kata gives a pod
its own kernel in a VM, gVisor gives it a userspace kernel — the sentry — which
intercepts syscalls in a normal host process. Cheaper than a VM, a narrower
syscall surface than runc, and no virtualization needed.

Unlike kata it is not extension-only. It needs machine config too, which is what
the per-node `patches:` key in `cluster.yaml` delivers:

```yaml
cp-0:
  extensions:
    - siderolabs/gvisor
  patches:
    - gvisor.yaml
```

Adding it to a node costs two reboots, in this order: `apply` first, because the
machine config carries files and Talos refuses to apply that in immediate mode,
then `upgrade` to land the image that has the extension. Doing it the other way
round leaves a node briefly running a `runsc-netraw` handler whose shim binary
does not exist yet.

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
(`ng/flux/infrastructure/gvisor`) points at `runsc-netraw` and, like kata's,
selects the control-plane role — which on this cluster means the three LAN
hosts, and keeps pods off `edge-0`, which has no extension.

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

### Sysbox, and extensions the factory does not have

`ghcr.io/yyewolf/talos-sysbox-extension` is not on the Image Factory. The
factory only layers extensions from its own registered set, and an OCI
reference in `extensions:` is accepted at upload time but rejected when the
image is actually built:

```
error enhancing profile from schematic: official extension
"ghcr.io/yyewolf/talos-sysbox-extension@sha256:…" is not available for Talos
version v1.13.7
```

So it goes under `custom_extensions:` in `cluster.yaml` instead, pinned by
digest, and the installer is built here rather than by the factory:

```yaml
cp-0:
  extensions:
  - siderolabs/kata-containers
  - siderolabs/gvisor
  custom_extensions:
  - ghcr.io/yyewolf/talos-sysbox-extension@sha256:e92ae18c…
```

```sh
./talos.sh installer cp-0        # build, push, remember the digest
./talos.sh render cp-0
./talos.sh upgrade cp-0
```

`installer` resolves the node's *complete* extension set — the official ones
from `schematic.yaml` and `extensions:`, at the exact refs and digests the
factory publishes for this Talos version, plus the custom ones — and hands all
of them to `siderolabs/imager`. It pushes to `installer_repository` and
remembers the resulting digest under `out/installer/`, which `render` then
writes into `machine.install.image`.

**`--system-extension-image` replaces, it does not add.** Handing imager only
the custom extension produces an image carrying only that extension, even with
`--base-installer-image` pointing at the node's factory installer. Done by hand
once, that left cp-2 without `iscsi-tools`: `longhorn-manager` died on a missing
`iscsiadm` and every Longhorn volume on the node refused to attach. This is why
`installer` builds the list from the whole extension set and why it is a command
rather than a comment.

The build is keyed on a hash of that list, so nodes sharing an extension set —
all three LAN hosts do — build and push one image between them. Change the list
and `render` refuses with a stale image rather than guessing; run `installer`
again.

Two things that follow from living outside the factory:

- `out/installer/` is throwaway like everything else in `out/`, but unlike a
  schematic ID it cannot be re-derived by asking a service. A fresh clone needs
  `installer` run once before `render`.
- The image is Talos-version-specific. Bumping `talos_version` means running
  `installer` again before `render`, or the node installs the old version while
  the rest of the cluster moves on.

`patches/sysbox.yaml` carries the rest: the `sysbox-mgr`/`sysbox-fs` static pod,
the netfilter modules, and the `yewolf.fr/sysbox` node label the RuntimeClass
selects on. The daemons are a **static pod**, not extension services, because
they act on host PIDs and extension services get a private PID namespace —
`setns(2)` into an ancestor PID namespace returns `EINVAL`, so the `nsenter`
workaround an earlier build used crash-looped. `hostPID: true` on a static pod
is the supported way.

Sysbox depends on `patches/gvisor.yaml` for `user.max_user_namespaces`: sysbox
has no mode that does not use unprivileged user namespaces, and Talos ships that
sysctl at 0. Drop gvisor.yaml from a node that keeps sysbox.yaml and every
sysbox container fails to start.

The `sysbox` RuntimeClass comes from `ng/flux/infrastructure/sysbox`. Not to be
confused with the RuntimeClass *named* `sysbox-runc` in
`ng/flux/infrastructure/gvisor/compat-sysbox-runc.yaml`, which is a migration
shim pointing at gVisor and keeps that meaning.

## Longhorn storage

`cp-0`, `cp-1` and `cp-2` each give Longhorn a dedicated 100 GiB partition of
their 256 GB NVMe. `patches/longhorn.yaml` is the whole story:

| document | what it does |
|---|---|
| `machine.kubelet.extraMounts` | binds `/var/mnt/longhorn` into the kubelet, `rshared` |
| `VolumeConfig` `EPHEMERAL` | caps `/var` at 128 GiB instead of the whole disk |
| `UserVolumeConfig` `longhorn` | a fixed 100 GiB partition, mounted at `/var/mnt/longhorn` |

The point of the partition is isolation. Longhorn's default data path is a
directory on `EPHEMERAL`, which puts replica data, container images and logs on
one filesystem — either one filling it takes the kubelet down with it. A
separate partition means neither can starve the other.

`iscsi-tools` and `util-linux-tools` are already in `schematic.yaml`, so this
costs no re-image. `edge-0` is deliberately excluded: it has no partition carved
for it, and replicating over the WireGuard tunnel to Infomaniak would be slow.
The Flux side pins every Longhorn component to the control-plane role to match
(`ng/flux/infrastructure/longhorn`), where `defaultDataPath` is set to
`/var/mnt/longhorn` — that value and the `UserVolumeConfig` name have to agree,
or Longhorn falls back to `/var/lib/longhorn` on `EPHEMERAL` and the partition
sits unused.

### Storage classes

100 GiB per node, three nodes, so 300 GiB raw — how much usable depends on the
class a claim picks:

| class | replicas | dataLocality | usable per GiB claimed | survives losing a node |
|---|---|---|---|---|
| `longhorn` (default) | 3 | `disabled` | 3 GiB | yes |
| `longhorn-ha` | 2 | `best-effort` | 2 GiB | yes |
| `longhorn-yolo` | 1 | `strict-local` | 1 GiB | no |

All three are `reclaimPolicy: Retain`, so deleting a PVC never destroys data —
it leaves a `Released` PV and the Longhorn volume behind. That is the point,
and it has a running cost: nothing reclaims those, they keep occupying the
100 GiB budget, and a full partition will look like a provisioning failure
rather than a pile of orphans. `kubectl get pv | grep Released` is a chore
someone has to do. Note also that a `Released` PV will *not* rebind to a
recreated PVC — its `claimRef` still points at the old one, so the app comes
back with an empty volume until `.spec.claimRef` is cleared by hand.

All three are also `WaitForFirstConsumer`, which is the half of "run the workload
where its data is" that Kubernetes enforces: nothing is provisioned until a pod
using the claim is scheduled, so replicas are placed around the node the
scheduler picked rather than the pod being dragged toward a volume that landed
somewhere arbitrary at apply time.

`dataLocality` is the other half, and it is set per class for a reason.
`longhorn` uses `disabled` because with three replicas across exactly three
storage nodes every node already holds one — locality is satisfied by
construction. `longhorn-ha` is where `best-effort` matters: two replicas over
three nodes leaves one node without, so Longhorn keeps one on whichever node
the workload is attached to and rebuilds a local replica if the pod moves.
`longhorn-yolo` is `strict-local`, the only one that genuinely pins scheduling —
the single replica sits on the pod's node, Longhorn puts `nodeAffinity` on the
PV, and I/O never leaves the box. It requires exactly one replica and does not
support RWX.

`longhorn-yolo` is the right choice under something that already replicates at
the application layer — a CNPG or CNMSQL cluster, where three instances on
1-replica volumes beat three instances on 3-replica volumes writing nine copies
of the same data.

### Adding it to a node means wiping EPHEMERAL

This is the one part that is not a normal `apply`. Talos applies volume sizing
**only at provisioning time** — "applying changes after the initial provisioning
will not have any effect". `EPHEMERAL` grows to fill the disk on first boot, so
on a node that is already running there is no unallocated space for the user
volume, and the 128 GiB cap is ignored rather than enforced. The partition only
appears if `EPHEMERAL` is destroyed and re-provisioned under the new config.

`EPHEMERAL` is `/var`, which holds etcd's data directory. Wiping it on a
control-plane node destroys that node's etcd member; a graceful reset makes it
leave the quorum first and rejoin as a new member on boot. **One node at a
time** — three members tolerate exactly one being away.

```sh
./talos.sh render
./talos.sh apply cp-0                       # config first: the cap must be in
                                            # place before the volume is rebuilt

talosctl -n 10.200.0.11 reset \
    --system-labels-to-wipe EPHEMERAL \
    --graceful --reboot
```

Wait for the node to come back `Ready` and for etcd to report three healthy
members before touching the next one:

```sh
kubectl get nodes -w
talosctl -n 10.200.0.11 etcd members
talosctl -n 10.200.0.11 get volumestatus     # u-longhorn should be 'ready'
```

Then repeat for `cp-1` and `cp-2`. What is lost per node is container images,
logs and that node's etcd copy — all of which come back on their own. What is
*not* automatically safe is Longhorn replica data, so once volumes exist this
sequence needs the usual replica-rebuild wait between nodes, not just an etcd
check.

## Upgrades

Bump `talos_version` in `cluster.yaml`, then `./talos.sh installer <node>` for
any node with `custom_extensions:` (all three LAN hosts, currently), then
`./talos.sh render`. The installer image in each config now points at the new
version, and:

```sh
./talos.sh upgrade cp-0        # then cp-1, then cp-2
```

reboots each node onto it. One at a time: with three control-plane nodes, etcd
tolerates exactly one being away.

Changing the extension list — `schematic.yaml`, a node's `extensions:` or its
`custom_extensions:` — works the same way. It is a new image, and `apply` alone
will not deliver it: `machine.install.image` only decides what the *next*
install writes, so an extension added to a running node needs the upgrade.

### The drain will not finish, and that is expected

`upgrade` drains the node first and **asks before continuing if the drain
blocks**. On this cluster it always blocks, and waiting does not help:
`longhorn-yolo` is `numberOfReplicas: 1` with `strict-local` data locality, so a
node holding one of those volumes holds its *last* replica, and Longhorn's
default `block-if-contains-last-replica` drain policy pins that node's
`instance-manager` PDB at zero allowed disruptions permanently.

By the time it asks, the workloads are already off the node; what is left is
DaemonSets and Longhorn's own node agents, which come back on reboot. The
volume data is on the node's disk and survives. So the answer is normally yes —
but it prints what is still running first, and anything stateful in that list
is about to be interrupted. Answering no uncordons the node and stops.

Left to `talosctl upgrade`, the same situation ends with the drain timing out,
the upgrade aborting, and the node cordoned with its stateful pods already
evicted — which is why the drain is driven here instead.

## Notes

- `talosctl validate --config out/<node>.yaml --mode metal` checks a rendered
  config before you apply it.
- `out/` is `chmod 700` and the rendered configs `0600`: they contain the
  decrypted cluster PKI.
- The Image Factory is a public, content-addressed build service. Uploading
  `schematic.yaml` publishes only the extension list, no secrets, and an
  unchanged file always resolves to the same ID.
