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
