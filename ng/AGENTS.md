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
- **Envoy Gateway** is the ingress controller (`envoy-gateway` KS). CRDs are installed via the `gateway-crds` Helm chart (`crds.gatewayAPI.channel: experimental` + `crds.envoyGateway.enabled: true`), the controller via the `eg` chart (`install.crds: Skip` since CRDs are managed separately). The proxy (`envoy-proxy` KS) is pinned to `edge-0` via `EnvoyProxy`, uses `externalIPs` to bind the public addresses directly, and terminates TLS with QUIC/HTTP3 listeners. HTTP/HTTPS (TCP 80, 443) plus QUIC (UDP 443) are opened in the OpenStack security group, and TCP 22 for `apps/portfoliosh`.
- **Opening a port on the edge is three separate consents, and two of them fail silently** — the Gateway listener (or a `ListenerSet` attached to it) is only the first. The OpenStack security group in `ng/openstack/main.tf` has to admit the public port, and the `proxy` policy in `platform/envoy-gateway/network-policy.yaml` has to admit `world` on the proxy's *translated* container port (80→10080, 443→10443, 22→10022), because Cilium enforces at the endpoint after the rewrite. Miss either and the listener still reports `Accepted`/`Programmed` with the route attached; the client just hangs on SYN. `hubble observe --verdict DROPPED` on the `edge-0` cilium pod tells the two apart — a packet that never arrives is Neutron, `Policy denied DROPPED` is Cilium.
- **A per-app listener goes in the app's directory as a `ListenerSet`, not in the shared Gateway** — `gateway.networking.k8s.io/v1`, the graduated API; Envoy Gateway 1.8 dropped the experimental `gateway.networking.x-k8s.io/v1alpha1` XListenerSet the root cluster still uses, in the same release it picked up the graduated one. The Gateway must consent: `allowedListeners` defaults to allowing *none*, and `platform/envoy-proxy/gateway.yaml` names the permitted namespaces by label selector rather than `All`, so a new namespace cannot open a public port from its own directory. See `apps/portfoliosh`.
- **external-dns writes the same zones cert-manager solves in** — `platform/external-dns` runs the upstream chart with `M0NsTeRRR/external-dns-webhook-infomaniak` as a webhook-provider sidecar (external-dns talks to it on `localhost:8888`; that is the upstream default, so no `--webhook-provider-url` is set). Sources are `gateway-httproute`, `service` and `crd`; the `DNSEndpoint` CRD comes from the chart's own `crds/`, so the HelmRelease uses `crds: CreateReplace`. `policy: sync` is only safe because of the TXT registry — records without a `k8s-` TXT owned by `ng` are never touched. `domainFilters` is the guard rail: a hostname outside `yewolf.fr`/`hackcorp.net` is silently ignored, not created.
- **The tailnet is shared with the root cluster, so nothing may take a default name** — `platform/tailscale` runs the Tailscale operator (chart `1.98.9`) against the same tailnet the root cluster's `applications/backbone/tailscale` already joined. The operator's own node is named `ng-tailscale-operator` explicitly, because the chart default (`tailscale-operator`) is already taken and a collision is resolved by silently appending `-1` rather than by an error. Tags are shared on purpose: `tag:k8s-operator` for the operator, `tag:k8s` for the proxies, so one set of ACL grants covers both clusters.
- **The OAuth credentials are a precreated Secret, not chart values** — `oauth.clientId`/`oauth.clientSecret` would make the chart template the credentials out of `HelmRelease.spec.values`, which is plaintext in git. Left empty, the operator falls back to mounting a Secret named `operator-oauth` in its namespace, which is `oauth-sops.yaml` (keys `client_id` and `client_secret` — underscores, not camelCase; the chart's own template uses the same names). Use a client distinct from the root cluster's so either can be revoked alone.
- **Cross-cluster access is two objects in two repos** — the side that owns the workload publishes it (a `Service` with `loadBalancerClass: tailscale`, or the `tailscale.com/expose` annotation), and the side that consumes it declares an `ExternalName` Service annotated `tailscale.com/tailnet-fqdn: <host>.<tailnet>.ts.net` with a placeholder `externalName` the operator overwrites. Neither half works alone: the consumer's ExternalName resolves to nothing until the publisher's proxy has registered. This is the path for pulling data out of the root cluster's databases into `ng` — root publishes `postgres-rw`/`mysql`, `ng` consumes them under a Service name the migration job dials.
- **A tailscale `Ingress` takes its hostname from `tls.hosts`, not from a rule host** — `apps/radar` is exposed as `radar-ng` (the root cluster already holds `radar`), and the only place that name appears is `spec.tls[0].hosts`. The chart's own ingress cannot express that, which is why `ingress.enabled: false` and the Ingress is a hand-written file. Renaming it later is not just a git edit: the old device lingers in the tailnet until it is deleted from the admin console, and the new name gets a `-1` suffix while it does.
- **Radar is unauthenticated on purpose and the tailnet is its only access control** — `auth.mode: none` with `rbac.helm`, `podExec` and `portForward` all on, so anything that can reach port 9280 can exec into any pod and drive Helm. Its network policy therefore admits ingress *only* from the `tailscale` namespace; that ingress rule is a security control, not tidiness. `rbac.crdGroups.all: true` for the same "private tailnet" reason — the chart's per-group list predates longhorn.io, barmancloud.cnpg.io, mysql.cnmsql.co and tailscale.com, so the alternative is editing `additionalCrdGroups` every time an operator lands.
- **`toFQDNs` cannot express DERP, so both tailscale policies open `world` on 443** — Cilium learns an FQDN's addresses by inspecting DNS answers, but tailscaled receives the relay list as a *derpmap* over its control-plane connection and dials those nodes by literal IP. No lookup happens for Cilium to observe, so a `*.tailscale.com` rule matches nothing and every relay is dropped: dozens of `Policy denied DROPPED (TCP Flags: SYN)` to assorted :443 addresses, from both the operator and the proxies, while the pod looks healthy. Pinning a `toCIDRSet` is not the fix either — the relay set rotates. This was tried the narrow way first and it does not work.
- **Both tailscale policies also need UDP to `world` on every port** — STUN to the relays, then WireGuard direct to whatever ip:port a peer turns out to be behind, neither knowable in advance. Unlike the 443 rule, restricting this does not produce drops that stop anything: it silently demotes the tunnel to relaying every byte through DERP.
- **The operator is a tailnet node, not just an API client** — so it probes and holds a DERP home relay exactly like a proxy does, and its policy ends up nearly identical to `tailscale-proxies`. The two are kept separate for their ingress rules and their selectors: `app: operator` versus `tailscale.com/managed: "true"`, which is the only label a proxy carries that does not name the Service it was created for. The proxies also talk to the apiserver because tailscaled keeps its node state in a Secret rather than on disk.
- **The API server proxy is off** (`apiServerProxyConfig.mode: "false"`) — cluster admin already comes over WireGuard from the LAN, and turning it on would put the apiserver on the tailnet behind a separate authorization path.
- **KEDA is two HelmReleases in one Kustomization** — `platform/keda` runs the `keda` chart (operator, metrics adapter, admission webhooks) and `keda-add-ons-http` (HTTP scale-to-zero), both in the `keda` namespace; the add-on `dependsOn` the core release because its CRD controller needs KEDA's `ScaledObject` API. `interceptor.replicas.min` stays at 1 — the interceptor scaling to zero would black-hole the wake-up request itself. Six CiliumNetworkPolicies cover the six workloads; none of them may reach `world`, so a trigger against a cloud API (SQS, Service Bus) needs a `toFQDNs` rule added to `keda-operator`. Two `toEntities: [cluster]` egress rules are deliberately loose because their targets are user-defined: the operator dials whatever scaler a `ScaledObject` names, and the interceptor forwards to whatever Service an `InterceptorRoute` names.
- **HTTP scale-to-zero is three objects, not one** — this cluster uses `InterceptorRoute` (`http.keda.sh/v1beta1`) + a plain KEDA `ScaledObject`, not the older all-in-one `HTTPScaledObject` the root cluster still runs. The `InterceptorRoute` carries routing and the scaling *metric* but no replica counts; the `ScaledObject` carries `minReplicaCount: 0` and an `external-push` trigger whose `interceptorRoute` metadata **must equal the InterceptorRoute's `metadata.name`**. Get that name wrong, or let the `ScaledObject` reconcile before the route exists, and the scaler returns an empty metric spec — the HPA then silently falls back to a CPU metric and the app never wakes, with no error anywhere. The third object is the `HTTPRoute`, whose `backendRef` is `keda-add-ons-http-interceptor-proxy:8080` in `keda`, never the app's own Service; the `InterceptorRoute` picks the real backend off the Host header. See `apps/cyberchef`.
- **A cross-namespace `backendRef` needs consent from the namespace being pointed at** — so the `ReferenceGrant` for every scale-to-zero app lives in `platform/keda/reference-grants.yaml`, not in the app's own directory. Adding an app means adding a grant there too, or the route attaches and returns 500 with no obvious cause. Same pattern as `platform/certificates/reference-grant.yaml` for the Gateway's cross-namespace `certificateRefs`.
- **`booting-up` is the shared cold-start placeholder** — a Caddy serving one self-refreshing page from a ConfigMap. An app opts in via `coldStart.fallback` on its `InterceptorRoute`, which resolves Service names in the *app's own* namespace, so each app also carries a `service-fallback` `ExternalName` aliasing `caddy.booting-up.svc.cluster.local`. Pair it with a short `timeouts.readiness` (cyberchef uses 2s): that value is how long a request hangs before it gets the placeholder instead. The page polls `/is_still_booting_up`, which keeps hitting the placeholder until the real pod is ready and then reloads.
- **Two database operators, both cluster-wide** — `platform/cnpg` (CloudNativePG, Postgres) and `platform/cnmsql` (CNMSQL, Percona Server for MySQL / MariaDB; upstream is `github.com/cnmsql/cnmsql`, docs at `cnmsql.co`). Both run with cluster-scoped RBAC (`config.clusterWide` / `rbac.namespaced: false`), so a `Cluster` is declared in the *app's* namespace, not the operator's. Their network policies end in `toEntities: [cluster]` for the same unavoidable reason KEDA's do — the instance pods they drive can be anywhere. Neither operator reaches `world`: backups and WAL/binlog archiving to S3 are the *instance* pods' egress, and those pods get their own policy in the app's directory.
- **CNPG and CNMSQL get their webhook certs differently** — CNPG's operator issues and rotates its own, so its KS only `dependsOn` `cilium`. CNMSQL's chart creates a self-signed cert-manager `Issuer` plus `Certificate`s and leans on cainjector for the webhook `caBundle`, so its KS `dependsOn` `cert-manager` — reconcile it before cert-manager is ready and the webhook stays certless and every `Cluster` apply is rejected.
- **CNMSQL ships no HTTP Helm repository** — the chart is GHCR-only (`oci://ghcr.io/cnmsql/charts/cnmsql`), so it uses an `OCIRepository` + `chartRef` like `envoy-gateway`, not the `HelmRepository` + `chart.spec` form the other platform apps use. Renovate's `flux` manager reads `OCIRepository.spec.ref.tag`, so it is still pinned and still bumped.
- **Longhorn gets a real partition, not a directory** — `patches/longhorn.yaml` (on cp-0/1/2) caps `EPHEMERAL` at 128GiB with a `VolumeConfig` and carves a fixed 100GiB `UserVolumeConfig` named `longhorn` out of the same NVMe, which Talos mounts at `/var/mnt/longhorn`. The default data path is a directory on `EPHEMERAL`, where replica data would compete with container images and logs and either one filling the filesystem takes the kubelet with it. `defaultSettings.defaultDataPath` in `flux/infrastructure/longhorn/release.yaml` must equal `/var/mnt/<UserVolumeConfig name>`; disagree and Longhorn silently falls back to `/var/lib/longhorn` on `EPHEMERAL` with no error. The kubelet also needs the `extraMounts` bind with `rshared` — without the propagation flag the per-volume mounts Longhorn creates never reach the pods that asked for them, and `statfs` reports `EPHEMERAL`'s free space for the disk.
- **Talos volume sizing only applies at provisioning time**, so adding Longhorn to a live node is a wipe, not an `apply` — `EPHEMERAL` already fills the disk, leaving no unallocated space, and the new cap is ignored rather than enforced. The sequence is `apply` the config, then `talosctl -n <ip> reset --system-labels-to-wipe EPHEMERAL --graceful --reboot`, one node at a time. `EPHEMERAL` is `/var`, which holds etcd's data directory: the graceful reset leaves the quorum and the node rejoins as a new member on boot, and three members tolerate exactly one being away. Full procedure in `talos/README.md` under "Longhorn storage".
- **Three StorageClasses, all declared by hand** — `longhorn` (3 replicas, the default class), `longhorn-ha` (2), `longhorn-yolo` (1), in `flux/infrastructure/longhorn/storageclasses.yaml` with the chart's `persistence.createStorageClass: false`. The chart can only express one class, and it does so via a ConfigMap that longhorn-manager converts into the real object — so leaving it on would describe the default class in a different form and a different file from the two beside it. The three differ only in replica count and `dataLocality`.
- **All three are `reclaimPolicy: Retain`, deliberately** — the chart default is `Delete`, which makes deleting a PVC (by hand, or by Flux pruning, or by a chart being uninstalled) an unrecoverable data loss with no confirmation step. The cost is that retained volumes are not garbage-collected: a deleted PVC leaves a `Released` PV and a Longhorn volume occupying the 100 GiB budget forever, so `kubectl get pv | grep Released` is real housekeeping and exhausting the partition will present as a provisioning failure rather than as a pile of orphans. Retain also does *not* mean "reattaches next time" — a `Released` PV keeps a `claimRef` to the vanished PVC and will not bind to a new one, so recreating the app gets a fresh empty volume until someone clears `.spec.claimRef` by hand. `reclaimPolicy` is stamped onto a PV at provisioning time, so changing it in a StorageClass only affects volumes created afterwards.
- **`volumeBindingMode: WaitForFirstConsumer` on all three** is the part of "run the workload where its data is" that Kubernetes actually enforces — provisioning waits for the pod to be scheduled, so replicas are placed around the chosen node instead of the pod being drawn to a volume provisioned arbitrarily at apply time. `dataLocality` covers the rest, and only `strict-local` (on `longhorn-yolo`) truly pins scheduling, because a Longhorn v1 volume is network-reachable from any node and so no other class's PV carries `nodeAffinity`. `longhorn` sets `dataLocality: disabled` deliberately: 3 replicas + `replicaSoftAntiAffinity: false` + exactly 3 storage nodes means every node already holds a replica and `best-effort` would have nothing to do.
- **`strict-local` needs exactly one replica** — Longhorn rejects volume creation otherwise — and does not support RWX. Never add `allowedTopologies` to `longhorn-yolo`: the PV `nodeAffinity` that produces is immutable and collides with strict-local's own pinning.
- **Longhorn's network policy selects the whole namespace, on purpose** — only `longhorn-manager`, `longhorn-driver-deployer` and `longhorn-ui` come from the chart. The instance managers, the CSI plugin and its sidecars, the share managers and the backing-image managers are created at runtime with labels that depend on which volumes exist, so a per-workload `endpointSelector` would cover the three static pods and default-deny everything that actually moves replica data. Engine-to-replica traffic uses dynamic ports in the 10000-30000 range, which is why the intra-namespace rule is portless. Nothing reaches `world` — `upgradeChecker` is off for that reason, and configuring an S3 backup target later is what would need a `toFQDNs` rule added.
- **edge-0 is not a storage node** — no partition is carved for it and replicating over the WireGuard tunnel to Infomaniak would be slow. Its `edge-0=true:NoSchedule` taint already keeps Longhorn off it, but every component also carries a control-plane `nodeSelector` so that an untainted worker added later does not silently become a storage node. Stateful workloads therefore stay on the LAN hosts.
- **There is one Postgres for the whole cluster** — `platform/postgres`, a two-instance CNPG `Cluster` in the `postgres` namespace. Apps do not get their own instance; they get a database on this one, declared with a `Database` CR **in the app's own namespace** pointing at `cluster: postgres`. That cross-namespace reference only works because `platform/cnpg` runs with `config.clusterWide: true`. Connection endpoints are `postgres-rw` (primary, writes), `postgres-ro` (standby, reads) and `postgres-r` (any instance), all in `postgres`.
- **Replication is async and that is deliberate at two instances** — a synchronous standby that goes away blocks every write on the primary, which would turn "one node is down" from survivable into a total outage. The cost is a bounded window of transactions that exist only on the primary if it dies abruptly. Anti-affinity is `required`, not the default `preferred`: two instances on one node is two copies on one disk and a replica pair that dies together.
- **VectorChord needs a CNPG-derived image, not just any Postgres image with the extension** — `ghcr.io/tensorchord/cloudnative-vectorchord` is built *from* the official CNPG image, so it keeps barman-cloud, the instance-manager entrypoint and the uid-26 postgres user. `tensorchord/vchord-postgres` and `vchord-suite` are built on the upstream postgres image and CNPG cannot drive them — they are not drop-in substitutes. Tag format is `<postgres>-<vectorchord>` (currently `18.4-1.1.1`).
- **`vchord.so` must be in `shared_preload_libraries`** — CREATE EXTENSION alone is not enough, the background workers load at startup and the extension fails at query time without it. Changing that list restarts the cluster.
- **`CREATE EXTENSION vchord` goes in `postInitTemplateSQL`, not `postInitApplicationSQL`** — template1 is what every later database is cloned from, so putting it there makes vchord present in every app database automatically instead of each app having to remember. `CASCADE` pulls in pgvector, which vchord builds on and the image ships. Bootstrap SQL runs **exactly once, at cluster creation**: editing it later does nothing to a running cluster, and an existing database would need the extension added by hand or via the `extensions` field on its own `Database` CR.
- **Postgres uses `longhorn-yolo` on purpose** — CNPG already keeps a second copy on the other instance, so a 3-replica class would write six copies of every transaction to protect against a failure CNPG already handles, and `strict-local` keeps Postgres reads and writes off the network. The trade is that losing a node's disk destroys that instance outright; the recovery is CNPG re-cloning it from the survivor, which is what the second instance is for.
- **There are no Postgres backups yet** — no `backup:` stanza, because `ng` has no S3 target at all. Two instances cover node loss; they do not cover `DROP TABLE`, corruption replicating to the standby, or losing the cluster, and every app's data is on this one Postgres. Closing it is a `backup.barmanObjectStore` block, a credentials Secret, a `ScheduledBackup`, and a `toFQDNs` egress rule in its network policy — `world` is denied outright today.
- **There is one MySQL for the whole cluster too** — `platform/mysql`, a two-instance CNMSQL `Cluster` (`mysql.cnmsql.co/v1alpha1`, note the group is *not* `cnmsql.co`) in the `mysql` namespace, deliberately the same shape as `platform/postgres`. Percona Server for MySQL 8.4. Apps get a database via a `Database` CR in their own namespace; that works because `platform/cnmsql` sets `rbac.namespaced: false`.
- **CNMSQL needs its own instance image, like CNPG does** — `ghcr.io/cnmsql/cnmsql-instance:8.4-4`, not stock `percona/percona-server`. The operator drives an instance manager that has to be present in the image. The tag is `<series>-<build>`; `8.4-4` is what the floating `8.4` resolved to when it was pinned. **amd64 only**, so it can only run on cp-0/1/2 anyway.
- **`flavor` and `replication.mode` are both immutable after creation** — changing either means rebuilding the cluster and restoring from a dump, so both are stated explicitly rather than left to their defaults.
- **MySQL is async + semi-sync, not Group Replication, because there are two instances** — a Group Replication group needs an odd member count to hold a quorum, so a two-member group cannot form one after losing a member, which is the exact failure it would exist to survive. Quorum would mean `instances: 3`. Instead `mysql.semiSync.enabled: true` makes the primary wait for the replica to acknowledge a commit, with **`dataDurability: preferred`** doing the important work: under `required` the ack count is fixed and a downed replica blocks every write until it returns, while `preferred` self-heals the count down to the healthy replica count so the pair degrades to async and stays writable. `maxSyncReplicas` must stay below `instances`, so this pair can only ever be 1/1.
- **`binlogFormat: ROW` is not optional** — it is the only format safe for both replication and PITR; `STATEMENT` silently diverges the replica on any non-deterministic statement.
- **MySQL bootstraps `utf8mb4`/`utf8mb4_0900_ai_ci` explicitly** — MySQL's historical `utf8` is a three-byte subset that cannot store emoji or much of CJK, and the mistake only surfaces later as data that will not insert.
- **Postgres backups go through the Barman Cloud plugin, never the in-tree `spec.backup.barmanObjectStore`** — the in-tree integration has been deprecated since CNPG 1.26 and was *slated for removal in 1.30*, which is the version running here. It survived, and the schema is still in the CRD, so it will silently accept configuration — but building on it means a forced migration on some future operator bump, found out during a restore. `platform/barman-plugin` installs the plugin (OCIRepository + HelmRelease, chart `0.7.0` = appVersion `v0.13.0`) into **cnpg-system**, which is mandatory: CNPG discovers the plugin over a Service in its own namespace. The destination is an `ObjectStore` CR (`barmancloud.cnpg.io/v1`) in the `postgres` namespace, referenced from `Cluster.spec.plugins` with `isWALArchiver: true` and from the `ScheduledBackup` via `method: plugin`. All three `barmanObjectName` values must name the same ObjectStore.
- **The barman plugin's network policy is split across two namespaces, deliberately** — the plugin Deployment in `cnpg-system` never uploads anything; it hands configuration to a sidecar the operator injects into each Postgres instance pod. So the `toFQDNs` rule for the bucket lives in `platform/postgres/network-policy.yaml`, next to the pods that actually talk to S3, and `platform/barman-plugin/network-policy.yaml` has no `world` egress at all. The instance pods also need egress to the plugin on 9090 (CNPG-I gRPC).
- **`wal.compression` and `data.compression` do not accept the same codecs** — WAL allows `bzip2/gzip/lz4/snappy/xz/zstd`, data allows only `bzip2/gzip/lz4/snappy`. `zstd` under `data` is rejected by the CRD. This cluster uses `zstd` for WAL (higher volume, latency-sensitive) and `gzip` for base backups (bottleneck is bytes on a home uplink, not CPU).
- **The two databases back up to two different Infomaniak accounts, not two prefixes in one bucket** — Postgres to `sb_project_SBI-TS165990`, MySQL to `sb_project_SBI-TS538856`. Neither set of credentials can read or delete the other's archive. Both use bucket `default` with a `/postgres` or `/mysql` prefix, which is tidiness rather than isolation.
- **CNPG's `ScheduledBackup` schedule also has six fields** — same seconds-first gotcha as CNMSQL's. Postgres runs at `"0 30 3 * * *"` (03:30), an hour after MySQL's 02:30, so the two are not competing for the same disks and uplink.
- **MySQL backs up natively; CNMSQL has no plugin split** — `platform/mysql` uses `backup.objectStore` directly on the Cluster (bucket `default`, prefix `/mysql`, region `us-east-1`, path-style, credentials from the SOPS-encrypted `mysql-backup-s3` Secret). `continuousArchiving` ships binlogs (`targetRPOSeconds: 300`) and a `ScheduledBackup` takes a nightly xtrabackup base backup from the standby, 30d retention on both. This is *not* the deprecated shape — it is CNMSQL's own current API, unrelated to CNPG's in-tree barman deprecation.
- **`backup.reclaimPolicy` defaults to `Retain` and should stay there** — `Delete` attaches a finalizer that wipes the *entire* archive (every base backup, every binlog, the index) when the Cluster is deleted, which is the same class of unpleasant surprise the `Retain` reclaim policy on the StorageClasses exists to avoid.
- **A `toFQDNs` rule needs L7 DNS visibility to work** — Cilium learns a name's addresses by inspecting DNS answers, so the kube-dns egress rule in `platform/mysql/network-policy.yaml` carries `rules.dns.matchPattern: "*"`. Without it the FQDN entry never populates and every upload is dropped *while the name still resolves fine from inside the pod* — which is a genuinely confusing failure. Equally, that must remain the only DNS egress rule: a second, plain allow to kube-dns alongside it lets lookups bypass inspection and reintroduces the same bug.
- **The backup cron has six fields, not five** — `schedule: "0 30 2 * * *"` is 02:30:00 daily. CNMSQL's `ScheduledBackup` includes a seconds field, so a normal five-field crontab line is misparsed rather than rejected.
- **Both database network policies key off the operator's real pod labels** — `app.kubernetes.io/name: cloudnative-pg` in `cnpg-system`, `app.kubernetes.io/name: cnmsql` in `cnmsql`. Both were checked against the running pods; the CNMSQL operator also carries `control-plane: controller-manager`, which is not matched on.
- **CNPG's `Cluster` uses `imageName:`, which no built-in Renovate manager reads** — the `kubernetes` manager only looks at `image:`, and the repo's original custom manager only matches a bare `tag:`/`version:` value, not a full repository:tag reference. A second `customManagers` entry in `renovate.json` handles `imageName:` and splits the repo from the tag. Under `versioning=docker` the trailing `-1.1.1` is a compatibility suffix, so Renovate offers Postgres patch bumps *within* that VectorChord version and never moves the extension on its own — a VectorChord upgrade is a deliberate edit.
- **Every version in `flux/` is pinned exactly, so Renovate can see it** — the bot is Renovate (`renovate.json` at the repo root), not Dependabot; Dependabot has no Flux support at all. A floating `version: "*"` or `"1.21.x"` in a `HelmRelease` gives it nothing to bump, so upgrades happen silently at reconcile time with no PR and no record of what changed. Renovate's `flux` manager reads `HelmRelease.spec.chart.spec.version` and `OCIRepository.spec.ref.tag`; an image pinned *inside* a chart's `values:` is invisible to every built-in manager, so it needs a `# renovate: datasource=docker depName=<image>` comment on the line above `tag:` — the `customManagers` regex in `renovate.json` keys off exactly that.
- **The Infomaniak API token exists twice, once per namespace** — cert-manager's solver reads `infomaniak-api-credentials` in `cert-manager`, external-dns reads `infomaniak-credentials` in `external-dns`. Secrets do not cross namespaces; the token has to be created in both.
- **SOPS secrets *are* reconciled from git on `ng`** — the `sops-gpg` Secret exists in `flux-system`, and `platform/certificates`, `platform/external-dns` and `platform/mysql` each list their `*-sops.yaml` in `kustomization.yaml` and carry a `decryption: {provider: sops, secretRef: {name: sops-gpg}}` block in `ks.yaml`. Adding a secret means: write it with `stringData`, name it `*-sops.yaml` so `.sops.yaml` matches it, `sops -e -i` it, add it to the kustomization, and make sure that app's `ks.yaml` has the decryption block — a missing decryption block fails as the *encrypted* Secret being applied verbatim, not as an error. `sops-gpg` itself is the one secret applied out of band: it cannot come from the repo it unlocks.
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

# Re-provision a node's EPHEMERAL partition so a VolumeConfig size change takes
# effect (this is what carves the Longhorn partition). One node at a time; wait
# for Ready and three healthy etcd members in between.
./ng/talos/talos.sh apply cp-0
talosctl -n 10.200.0.11 reset --system-labels-to-wipe EPHEMERAL --graceful --reboot

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
flux reconcile kustomization longhorn
flux reconcile kustomization cert-manager
flux reconcile kustomization certificates
flux reconcile kustomization envoy-gateway
flux reconcile kustomization envoy-proxy
flux reconcile kustomization external-dns
flux reconcile kustomization keda
flux reconcile kustomization tailscale
flux reconcile kustomization cnpg
flux reconcile kustomization barman-plugin
flux reconcile kustomization cnmsql
flux reconcile kustomization postgres
flux reconcile kustomization mysql
flux reconcile kustomization booting-up
flux reconcile kustomization cyberchef
flux reconcile kustomization radar

# Watch Flux status
flux get kustomizations --watch
```
