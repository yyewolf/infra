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
    ├── platform/         # Services apps depend on: cert-manager, envoy, monitoring
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
- **System extensions are per node, not just per cluster** — `talos/schematic.yaml` is the shared image; a node can add its own under `extensions:` in its `cluster.yaml` entry, and `render` resolves the merged list to a separate Image Factory ID for that node alone. Off-LAN nodes cannot use it — `ng/openstack` builds `edge-0` from the base `out/schematic-id`, so `render` refuses if a WireGuard node lists extensions.
- **A node can carry extra machine config, not just extra extensions** — `patches:` in a node's `cluster.yaml` entry names files under `talos/patches/` that `render` applies to that node alone, between the generated patch and `nodes/<n>.yaml`. Use it when an extension needs config to go with it (gVisor does; kata does not).
- **gVisor runs on cp-0/1/2, like kata** — `siderolabs/gvisor` plus `patches/gvisor.yaml`, which sets `user.max_user_namespaces` (Talos ships it at 0; runsc cannot start without it) and registers a `runsc-netraw` handler running runsc with `--net-raw` and `--allow-packet-socket-write` for Docker-in-pod. The `gvisor` RuntimeClass (`flux/infrastructure/gvisor`) selects the control-plane role. The extension's own flagless `runsc` handler is deliberately left unexposed. Adding gVisor to a node is two reboots: `apply` (the machine config, which cannot go in immediate mode) then `upgrade` (the image).
- **A gVisor or kata pod bypasses Cilium's socket-LB** — the application's `connect()` happens inside the sandbox's own network stack (the runsc sentry, or the kata VM kernel), never as a host syscall, so ClusterIP translation has to come from the tc datapath instead of the cgroup hooks. This cluster has socket-LB off already (`bpf-lb-sock: "false"`, the chart default — the HelmRelease never enables it), so it works; the symptom when it does not is `to-network FORWARDED` in Hubble for a ClusterIP destination and no reply, with pod-to-pod and external traffic unaffected. A `cilium` restart was needed once to make the datapath pick this up.
- **`machine.files` can only `create` under `/var`** — outside `/var` the op must be `overwrite` or `append` on a file that already exists. A failed file write aborts `writeUserFiles`, which halts the boot sequence *before* the kubelet: the node stays reachable over `talosctl` but sits `NotReady` with `/etc/kubernetes` read-only. Fix the config and re-`apply`; no console needed.
- **`/etc/cri/conf.d/20-customization.part` is the only CRI drop-in path Talos accepts** — it is special-cased and injected as a config patch. Any other filename in that directory falls through to the file writer, hits the `/var` rule above, and halts the boot. Everything a node adds to containerd's config shares that one file.
- **Kata Containers runs on cp-0/1/2 only** — `siderolabs/kata-containers` is in those three nodes' extensions, deliberately not `edge-0`'s (no nested virt, and changing its config means Terraform recreating the instance). The extension registers the containerd handlers itself; the `kata` and `kata-qemu` RuntimeClasses live in `flux/infrastructure/kata` and pin scheduling to control-plane nodes so a kata pod cannot land on the edge.
- **Extension and version changes need `talos.sh upgrade <node>`, not `apply`** — `machine.install.image` only decides what the next install writes, so a running node keeps its old image until it is upgraded onto the new one. One node at a time; etcd tolerates one of three being away.
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
- **Envoy Gateway** is the ingress controller (`envoy-gateway` KS). CRDs are installed via the `gateway-crds` Helm chart (`crds.gatewayAPI.channel: experimental` + `crds.envoyGateway.enabled: true`), the controller via the `eg` chart (`install.crds: Skip` since CRDs are managed separately). The proxy (`envoy-proxy` KS) is pinned to `edge-0` via `EnvoyProxy`, uses `externalIPs` to bind the public addresses directly, and terminates TLS with QUIC/HTTP3 listeners. HTTP/HTTPS (TCP 80, 443) plus QUIC (UDP 443) are opened in the OpenStack security group.
- **external-dns writes the same zones cert-manager solves in** — `platform/external-dns` runs the upstream chart with `M0NsTeRRR/external-dns-webhook-infomaniak` as a webhook-provider sidecar (external-dns talks to it on `localhost:8888`; that is the upstream default, so no `--webhook-provider-url` is set). Sources are `gateway-httproute`, `service` and `crd`; the `DNSEndpoint` CRD comes from the chart's own `crds/`, so the HelmRelease uses `crds: CreateReplace`. `policy: sync` is only safe because of the TXT registry — records without a `k8s-` TXT owned by `ng` are never touched. `domainFilters` is the guard rail: a hostname outside `yewolf.fr`/`hackcorp.net` is silently ignored, not created.
- **KEDA is two HelmReleases in one Kustomization** — `platform/keda` runs the `keda` chart (operator, metrics adapter, admission webhooks) and `keda-add-ons-http` (HTTP scale-to-zero), both in the `keda` namespace; the add-on `dependsOn` the core release because its CRD controller needs KEDA's `ScaledObject` API. `interceptor.replicas.min` stays at 1 — the interceptor scaling to zero would black-hole the wake-up request itself. Six CiliumNetworkPolicies cover the six workloads; none of them may reach `world`, so a trigger against a cloud API (SQS, Service Bus) needs a `toFQDNs` rule added to `keda-operator`. Two `toEntities: [cluster]` egress rules are deliberately loose because their targets are user-defined: the operator dials whatever scaler a `ScaledObject` names, and the interceptor forwards to whatever Service an `InterceptorRoute` names.
- **HTTP scale-to-zero is three objects, not one** — this cluster uses `InterceptorRoute` (`http.keda.sh/v1beta1`) + a plain KEDA `ScaledObject`, not the older all-in-one `HTTPScaledObject` the root cluster still runs. The `InterceptorRoute` carries routing and the scaling *metric* but no replica counts; the `ScaledObject` carries `minReplicaCount: 0` and an `external-push` trigger whose `interceptorRoute` metadata **must equal the InterceptorRoute's `metadata.name`**. Get that name wrong, or let the `ScaledObject` reconcile before the route exists, and the scaler returns an empty metric spec — the HPA then silently falls back to a CPU metric and the app never wakes, with no error anywhere. The third object is the `HTTPRoute`, whose `backendRef` is `keda-add-ons-http-interceptor-proxy:8080` in `keda`, never the app's own Service; the `InterceptorRoute` picks the real backend off the Host header. See `apps/cyberchef`.
- **A cross-namespace `backendRef` needs consent from the namespace being pointed at** — so the `ReferenceGrant` for every scale-to-zero app lives in `platform/keda/reference-grants.yaml`, not in the app's own directory. Adding an app means adding a grant there too, or the route attaches and returns 500 with no obvious cause. Same pattern as `platform/certificates/reference-grant.yaml` for the Gateway's cross-namespace `certificateRefs`.
- **`booting-up` is the shared cold-start placeholder** — a Caddy serving one self-refreshing page from a ConfigMap. An app opts in via `coldStart.fallback` on its `InterceptorRoute`, which resolves Service names in the *app's own* namespace, so each app also carries a `service-fallback` `ExternalName` aliasing `caddy.booting-up.svc.cluster.local`. Pair it with a short `timeouts.readiness` (cyberchef uses 2s): that value is how long a request hangs before it gets the placeholder instead. The page polls `/is_still_booting_up`, which keeps hitting the placeholder until the real pod is ready and then reloads.
- **Two database operators, both cluster-wide** — `platform/cnpg` (CloudNativePG, Postgres) and `platform/cnmsql` (CNMSQL, Percona Server for MySQL / MariaDB; upstream is `github.com/cnmsql/cnmsql`, docs at `cnmsql.co`). Both run with cluster-scoped RBAC (`config.clusterWide` / `rbac.namespaced: false`), so a `Cluster` is declared in the *app's* namespace, not the operator's. Their network policies end in `toEntities: [cluster]` for the same unavoidable reason KEDA's do — the instance pods they drive can be anywhere. Neither operator reaches `world`: backups and WAL/binlog archiving to S3 are the *instance* pods' egress, and those pods get their own policy in the app's directory.
- **CNPG and CNMSQL get their webhook certs differently** — CNPG's operator issues and rotates its own, so its KS only `dependsOn` `cilium`. CNMSQL's chart creates a self-signed cert-manager `Issuer` plus `Certificate`s and leans on cainjector for the webhook `caBundle`, so its KS `dependsOn` `cert-manager` — reconcile it before cert-manager is ready and the webhook stays certless and every `Cluster` apply is rejected.
- **CNMSQL ships no HTTP Helm repository** — the chart is GHCR-only (`oci://ghcr.io/cnmsql/charts/cnmsql`), so it uses an `OCIRepository` + `chartRef` like `envoy-gateway`, not the `HelmRepository` + `chart.spec` form the other platform apps use. Renovate's `flux` manager reads `OCIRepository.spec.ref.tag`, so it is still pinned and still bumped.
- **Every version in `flux/` is pinned exactly, so Renovate can see it** — the bot is Renovate (`renovate.json` at the repo root), not Dependabot; Dependabot has no Flux support at all. A floating `version: "*"` or `"1.21.x"` in a `HelmRelease` gives it nothing to bump, so upgrades happen silently at reconcile time with no PR and no record of what changed. Renovate's `flux` manager reads `HelmRelease.spec.chart.spec.version` and `OCIRepository.spec.ref.tag`; an image pinned *inside* a chart's `values:` is invisible to every built-in manager, so it needs a `# renovate: datasource=docker depName=<image>` comment on the line above `tag:` — the `customManagers` regex in `renovate.json` keys off exactly that.
- **The Infomaniak API token exists twice, once per namespace** — cert-manager's solver reads `infomaniak-api-credentials` in `cert-manager`, external-dns reads `infomaniak-credentials` in `external-dns`. Secrets do not cross namespaces; the token has to be created in both. Neither is reconciled from git (the `*-sops.yaml` files under `platform/certificates/` are not in its `kustomization.yaml` and its `ks.yaml` has an empty `decryption.secretRef`) — they are applied out of band.
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

# Reboot a node onto its current installer image (after a version or
# extension change). One node at a time.
./ng/talos/talos.sh render && ./ng/talos/talos.sh upgrade cp-0

# Plan edge-0 OpenStack changes (uses encrypted state)
./ng/openstack/tf.sh plan

# Apply edge-0
./ng/openstack/tf.sh apply

# Init (no state file needed)
cd ng/openstack && terraform init

# Bootstrap Flux on the cluster (one-time, after Cilium is healthy)
flux bootstrap git --url=https://github.com/yyewolf/infra.git --branch=main --path=./ng/flux

# Force Flux to reconcile (without waiting for the interval)
flux reconcile kustomization shared
flux reconcile kustomization cilium
flux reconcile kustomization kata
flux reconcile kustomization cert-manager
flux reconcile kustomization certificates
flux reconcile kustomization envoy-gateway
flux reconcile kustomization envoy-proxy
flux reconcile kustomization external-dns
flux reconcile kustomization keda
flux reconcile kustomization cnpg
flux reconcile kustomization cnmsql
flux reconcile kustomization booting-up
flux reconcile kustomization cyberchef

# Watch Flux status
flux get kustomizations --watch
```
