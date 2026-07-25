# ng directory - Home network infrastructure

Terraform-managed home network config using the MikroTik RouterOS provider and SOPS for secrets.

## Structure

```
ng/
├── router/           # MikroTik router configuration
│   ├── main.tf       # Root: providers, data sources, module calls
│   ├── provider.tf    # RouterOS provider (192.168.1.49, insecure=true)
│   ├── variables.tf   # wan_interface, wan_hostname, lan_interface_list, wan_interface_list
│   ├── router-sops.yaml   # SOPS-encrypted router credentials (secrets.username, secrets.password)
│   └── modules/
│       ├── wan/          # DHCP client, ethernet, DNS, mDNS
│       ├── ip-firewall/  # IPv4 firewall filter + NAT rules
│       ├── ipv6-firewall/# IPv6 firewall filter + address lists
│       └── wireguard/    # WireGuard interface, IP, and peers
├── wireguard/
│   ├── identities-sops.yaml  # SOPS-encrypted WG identity registry
│   ├── gen-identity.sh       # Generate keypair for one identity
│   ├── gen-conf.sh           # Render a client .conf for one identity
│   └── gen-all.sh            # Regenerate all keys
├── openstack/            # Infomaniak OpenStack: the edge-0 Talos worker
│   ├── main.tf           # Glance image, port + secgroup, instance, floating IP
│   ├── provider.tf       # OpenStack + SOPS providers
│   ├── variables.tf      # flavor, networks, instance name
│   └── tf.sh             # State encryption wrapper
├── talos/                # Talos cluster definition (see talos/README.md)
│   ├── cluster.yaml      # Addressing, versions, node inventory — source of truth
│   ├── schematic.yaml    # Image Factory schematic
│   ├── secrets-sops-all.yaml  # Cluster PKI, fully encrypted
│   ├── patches/          # common / controlplane / worker config patches
│   ├── nodes/            # Per-node hardware facts (install disk)
│   └── talos.sh          # Driver: iso, usb, secrets, render, apply, bootstrap
├── cluster/              # Cluster infrastructure values (reference)
│   └── cilium/           # Cilium values.yaml — applied via Flux, kept as doc
├── flux/                 # Flux CD configuration
    ├── flux-system/      # Bootstrap — do not hand-edit
    ├── infrastructure/   # Cluster-critical: Cilium, CNI, storage, ingress
    ├── platform/         # Services apps depend on: cert-manager, monitoring
    └── apps/             # User applications
```

## Key conventions

- **SOPS encrypted files** must match pattern `.*-sops\.yaml$` in `.sops.yaml` at repo root. Encrypted keys go under `secrets:` key (matches `encrypted_regex: ^(data|stringData|secrets)$`).
- **RouterOS provider** connects to `https://192.168.1.49` with `insecure = true` (self-signed cert, no IP SANs).
- **Terraform modules** in `modules/` each declare their own `required_providers { routeros {} }` block (no version pin in sub-modules).
- **WireGuard identities** — private keys are under `secrets:` (encrypted), public keys/addresses/ports/endpoint under `identities:` (plaintext). Use `nonsensitive()` on the identities map when iterating peers since Terraform marks the whole `data.sops_file.raw` as sensitive.
- **Firewall rule IDs** — this router uses hex IDs (*A, *B, etc.), numbering starts at *1 (not *0).
- **Firewall rule order** — `modules/ip-firewall` pins every rule with `place_before` pointing at its successor, so table order equals declaration order regardless of when Terraform creates things. Adding a rule means splicing it into that chain.
- **Talos** — `talos/cluster.yaml` is the only place node addresses are written; `talos.sh render` derives hostnames, static addressing, VIP, cert SANs and the installer image from it. Never hand-edit anything in `talos/out/` — it is regenerated and holds decrypted PKI.
- **`-sops-all.yaml` suffix** — encrypts *every* value, not just keys named `secrets`. Required for bundles like the Talos PKI where the sensitive material is not under a `secrets:` key.
- **OpenStack edge-0** — a Talos worker, not a general-purpose VM. Its `user_data` *is* the machine config rendered by `ng/talos/talos.sh render edge-0`; `ng/openstack` defines no cluster config of its own and only reads `ng/talos/` (for the version, schematic ID and rendered config) and the WG registry (for the listen port). There is no cloud-init and no SSH.
- **edge-0 joins over WireGuard only** — the tunnel is declared in the Talos machine config, so it is up before the kubelet starts and the node never contacts the control plane over the bare internet. Its cluster address (`10.200.255.2`) is on `wg0`, not on the cloud NIC.
- **WireGuard addresses are cross-checked** — `talos.sh render` reads `ng/wireguard/identities-sops.yaml` and refuses to render if a node's address there disagrees with `cluster.yaml`. The router derives its routes from the same registry, so a mismatch would produce a tunnel that handshakes and carries nothing.
- **`gen-identity.sh` regenerates the keypair every run** — re-running it for a deployed node invalidates that node's rendered config. Set the endpoint at the same time as the initial key, not afterwards.
- **`network.wg_mtu` in `talos/cluster.yaml` and `MTU` in `cluster/cilium/values.yaml` must move together** (both 1420). Pod payload 1370 + VXLAN 50 exactly fills the tunnel.
- **Flux per-app Kustomizations** — each app gets its own Flux `Kustomization` (a `ks.yaml` in the app directory) that reconciles only that app. No directory-level Kustomization that reconciles everything in `infrastructure/` or `platform/` in one batch.
  - **Organization**: directories (`infrastructure/`, `platform/`, `apps/`) group apps by category, but each subdirectory has its own `ks.yaml`.
  - **Naming**: KS names are flat (`cilium`, not `infrastructure-cilium`). The directory path provides categorization; `dependsOn` chains read naturally (`cert-manager` waits on `cilium`, not `infrastructure-cilium`).
  - **dependsOn**: per-app. `cert-manager` → `dependsOn: [{name: cilium}]`. Apps only wait on what they actually need, not an entire layer.
  - **Adding a new app**: create `platform/<app>/` with `ks.yaml` + `kustomization.yaml` + resources, then add `platform/<app>/ks.yaml` to the root `ng/flux/kustomization.yaml`. The root Kustomization is the only place per-app KS CRDs are collected — not the parent directory.
  - The old directory-level Kustomizations (`infrastructure`, `platform`, `apps`) are deliberately absent. A per-app `cilium` Kustomization replaces them; the `ks.yaml` lives at `infrastructure/cilium/ks.yaml`, not `infrastructure/ks.yaml`.
- **edge-0 taint** — the cloud worker node carries `edge-0=true:NoSchedule`. Applications that tolerate this run on the edge (usually stateless, ingress-terminating workloads). Everything else stays on the LAN nodes by default — no `nodeSelector` needed on every workload.
- **Cilium is Flux-managed** via a HelmRelease in `ng/flux/infrastructure/cilium/`. The original `ng/cluster/cilium/values.yaml` is kept as documentation but is no longer consumed by `install.sh`. When changing Cilium values, update both files to keep them in sync.
- **Infomaniak has no floating IPs at all** — no network in the project is flagged `external`, so there is no pool to allocate from, and floating IPs are an IPv4 NAT construct with no IPv6 equivalent on any OpenStack. Instances attach directly to a shared dual-stack provider network (`ext-net1`: 21 public v4 /24s + `2001:1600:16:10::/64`, `dhcpv6-stateful`) and the port holds the public v4 and v6. `ext-v6only1` is the v6-only alternative. Do not reintroduce floating-IP or `enable_v6_fip`-style resources.
- **The edge-0 port is directly on the internet** — no NAT, no floating-IP indirection. The security group is the only thing in front of apid (50000) and the kubelet (10250). Neutron denies ingress by default, so the rules in `main.tf` are exhaustive; adding one exposes a port to the world.
- **edge-0's public IPv6 is ingress only** — never make it the node's Kubernetes address. `kubelet.nodeIP.validSubnets` pins the node to the WireGuard overlay; registering under the public v6 would route inter-node traffic over the open internet.
- **clouds.yaml entry names are `<project>-<region>`** (e.g. `PCP-SESBZOV-dc4-a`), not `openstack`. There is one entry per datacentre.
- **OpenStack provider v3 dropped the compute-side networking resources** — use `openstack_networking_port_v2` + `openstack_networking_floatingip_associate_v2`, not `openstack_compute_floatingip_associate_v2`.
- **State management** — both `ng/router/` and `ng/openstack/` use `tf.sh` wrappers with PGP-encrypted state files (`terraform-state.gpg`). They share the same PGP key.

## Rules

- **NEVER** read terraform state files (`*.tfstate`, `*.tfstate.backup`, `.terraform/`).
- **NEVER** read SOPS-encrypted files or decrypted secrets. Use `data.sops_file` in Terraform — do not inspect actual credential values.
- **NEVER** commit secrets, private keys, or unencrypted credentials.
- When adding a new WireGuard peer, run `./wireguard/gen-identity.sh <name> <address>` from the `ng/` directory, then update `router/main.tf` locals if needed.
- **Before planning `ng/openstack/`**, run `ng/talos/talos.sh schematic` and `ng/talos/talos.sh render edge-0` — the module reads `talos/out/schematic-id` and `talos/out/edge-0.yaml` and has preconditions that say so. The full bring-up order (floating IP first, because the router needs it as the peer endpoint) is in `ng/talos/README.md` under "The cloud worker".

## State management

State is encrypted with SOPS and committed to git. Use the wrapper script (`tf.sh`) instead of calling terraform directly — it decrypts state before use and re-encrypts on exit.

State file: `ng/router/terraform-state.gpg` (PGP-encrypted blob, tracked in git)
Plaintext: `ng/router/terraform.tfstate` (temporary, gitignored, never committed)

## Commands

```sh
# Plan router changes (uses encrypted state)
./ng/router/tf.sh plan

# Apply changes
./ng/router/tf.sh apply

# Destroy
./ng/router/tf.sh destroy

# Init (no state needed, but cd required)
cd ng/router && terraform init

# Regenerate all WireGuard keys
./ng/wireguard/gen-all.sh

# Add a new WireGuard identity
./ng/wireguard/gen-identity.sh my-peer 10.10.0.3/32

# Render edge-0's machine config first — ng/openstack consumes it
./ng/talos/talos.sh schematic && ./ng/talos/talos.sh render edge-0

# Plan edge-0 OpenStack changes (uses encrypted state)
./ng/openstack/tf.sh plan

# Apply edge-0
./ng/openstack/tf.sh apply

# Init (no state file needed)
cd ng/openstack && terraform init

# Bootstrap Flux on the cluster (one-time, after Cilium is healthy)
flux bootstrap git --url=https://github.com/yyewolf/infra.git --branch=main --path=./ng/flux

# Force Flux to reconcile (without waiting for the interval)
flux reconcile kustomization cilium
flux reconcile kustomization cert-manager
flux reconcile kustomization certificates

# Watch Flux status
flux get kustomizations --watch
```
