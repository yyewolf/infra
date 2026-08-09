# Plan: Frigate NVR in the home-assistant stack

Add a Frigate (NVR) StatefulSet to the existing `home-assistant` namespace, wired to the
existing Mosquitto broker and reachable only over the tailnet. CPU-only decode/detection.
Recordings to a dedicated `big-pool` PVC; config to a separate `big-pool` PVC. Camera RTSP
credentials and MQTT password injected from a SOPS Secret — nothing sensitive in git.

## Decisions (locked from user Q&A)

- **Namespace**: `home-assistant` (add to the existing multi-workload app, not a new one).
- **Hardware accel**: **CPU-only**. No `runtimeClassName`, no `nvidia.com/gpu` request, no
  `nvidia.com/gpu:NoSchedule` toleration. ffmpeg decode + object detection run on CPU.
- **Ingress**: **Tailnet-only** via a Tailscale Ingress (like zigbee2mqtt/esphome). No public
  HTTPRoute, no SSO. The tailnet is the access control.
- **Cameras**: user has RTSP URLs; count + host IPs to be filled at implement time. Plan
  templates the config and uses a broad LAN egress rule (scoped to 192.168.0.0/16 +
  10.0.0.0/8 on tcp/554) so it works regardless of exact host list.
- **Credentials**: RTSP URLs embed `user:pass` — **must never land in git**. The Frigate
  `config.yml` is rendered at container start from a ConfigMap template that substitutes
  camera credentials and the MQTT password from env vars backed by a SOPS Secret. Verify
  Frigate's env-substitution syntax (`FRIGATE_*` env-var templating) at implement time; if
  Frigate does not natively support it, fall back to an init container that runs `envsubst`
  over the ConfigMap into the config PVC.
- **Storage**: two named `big-pool` RWO PVCs (static claims, like the other HA workloads —
  NOT `volumeClaimTemplate`s): `frigate-config` (~10Gi) and `frigate-media` (start ~100Gi,
  expandable). Both labeled `recurring-job-group.longhorn.io/home-assistant-backup: enabled`
  so the existing nightly backup job covers them.

## Facts from the codebase (already verified)

- Mosquitto broker: `flux/apps/home-assistant/mqtt.yaml` — StatefulSet `mqtt`, Service
  `mosquitto` (NodePort 31883, ClusterIP on 1883 for in-cluster), ACL + password-file auth.
- MQTT credentials Secret: `flux/apps/home-assistant/mqtt-passwords-sops.yaml` (key
  `passwords`, a mosquitto password-file blob). Adding a Frigate user means appending a
  hashed line there + an ACL block in `mqtt.yaml`.
- MQTT network policy: `flux/apps/home-assistant/network-policy.yaml` policy `mqtt` admits
  ingress on 1883 from `zigbee2mqtt` endpoints + `host`/`remote-node`. Frigate is a pod
  endpoint (not hostNetwork), so it needs a `fromEndpoints: app: frigate` ingress rule on
  the `mqtt` policy, and a matching `toEndpoints: app: mqtt` egress rule on a new `frigate`
  policy.
- HA namespace PSA is `privileged` (`storage/namespace.yaml`), so a privileged/non-root pod
  is admissible; but Frigate CPU-only needs no privilege — target `runAsNonRoot: true`,
  `drop: [ALL]`, `seccompProfile: RuntimeDefault` (matches esphome/smartclock posture).
- Storage classes: `big-pool` (Retain, RWO, 1 replica, w-1 ZFS tank, `WaitForFirstConsumer`).
  The HA storage KS already has `wait: true` and "got away with it" (claims bound by hand);
  adding two more claims to the same `storage/storage.yaml` keeps them in the same KS.
- Backup label format: `recurring-job-group.longhorn.io/home-assistant-backup: enabled`
  (confirmed in `storage/storage.yaml`). The `home-assistant-backup` RecurringJob is in
  `flux/infrastructure/longhorn/backup-jobs.yaml`.
- Tailnet Ingress pattern: `ingressClassName: tailscale`, hostname in `spec.tls[0].hosts`
  (no rule host), backend = in-namespace Service. KS `dependsOn: tailscale`.
- Root app KS `flux/apps/home-assistant/ks.yaml` already `dependsOn: envoy-proxy` and
  `tailscale`, and has the SOPS `decryption` block (so a new `*-sops.yaml` here is covered).
- Root `flux/kustomization.yaml` already lists `apps/home-assistant/storage/ks.yaml` and
  `apps/home-assistant/ks.yaml` — **no root change needed** since we reuse the existing KSs.
- Images in this repo are digest-pinned (`image: ...@sha256:...`).

## Files to create / edit

### 1. `flux/apps/home-assistant/storage/storage.yaml` (EDIT — append two PVCs)

Append `frigate-config` (10Gi) and `frigate-media` (100Gi) big-pool RWO claims, both with
the `home-assistant-backup` recurring-job label. Follow the exact shape of the existing
three claims (static `PersistentVolumeClaim`, `accessModes: [ReadWriteOnce]`,
`storageClassName: big-pool`).

### 2. `flux/apps/home-assistant/frigate.yaml` (NEW — StatefulSet + Service + ConfigMap)

A hand-written StatefulSet `frigate`, 1 replica, `nodeSelector: kubernetes.io/hostname: w-1`
(consistent with the whole HA stack; cameras are on the LAN reachable from w-1, and big-pool
is w-1-only). NOT hostNetwork. CPU-only: no `runtimeClassName`, no GPU request.

Key structure:
- Container `frigate`, image `ghcr.io/blakeblackshear/frigate:<stable>@sha256:<digest>`
  (pin exact digest; pick the latest stable tag at implement time).
- `securityContext`: `runAsNonRoot: true`, `runAsUser/runAsGroup` to the image's uid (Frigate's
  official image runs as root by default — use `0` only if the image requires it; otherwise
  set a fixed non-root uid and `fsGroup` matching the PVC ownership). `allowPrivilegeEscalation:
  false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`.
- Ports: `8971` (web UI + internal API), `1935` (RTMP, optional), `8554` (RTSP re-stream, optional).
  Expose `8971` on the Service for the tailnet Ingress + HA integration.
- Env: `FRIGATE_MQTT_USER=frigate`, `FRIGATE_MQTT_PASSWORD` from the SOPS Secret key
  `frigate-mqtt-password`; `FRIGATE_RTSP_PASSWORD` (or per-camera) from Secret key
  `frigate-rtsp-password`. Exact env names depend on Frigate's templating support — verify.
- `shmSize: 1Gi` (Frigate recommends a large `/dev/shm` for shared memory between ffmpeg and
  detection; if the default is too small, detection fails with shm errors). Note: `shmSize`
  requires no privilege but is a pod-level field.
- `volumeMounts`: `/config` (frigate-config PVC), `/media` (frigate-media PVC), `/dev/shm`
  is the container's default tmpfs sized by `shmSize`.
- Config source: mount a ConfigMap `frigate-config-template` at `/config/config.yml` IF Frigate
  supports env-substitution in config; otherwise use an init container that runs `envsubst` over
  the template into `/config/config.yml` on the PVC (so credentials are resolved at runtime from
  env, never in git). Prefer the native path; fall back to init-container only if needed.
- `livenessProbe`/`readinessProbe`: httpGet `/api` on 8971.
- `resources`: requests memory 512Mi/cpu 500m, limits memory 2Gi (CPU-only decode is the
  constraint — tune to camera count at apply time).
- Volumes: `config` → PVC `frigate-config`, `media` → PVC `frigate-media`.
- Service `frigate` (ClusterIP), port 8971 named `http`.

ConfigMap `frigate-config-template` (in same file): a `config.yml` body templated with
placeholder camera count. Include:
- `mqtt:` block → `host: mosquitto`, `port: 1883`, `user: frigate`, `password: ${FRIGATE_MQTT_PASSWORD}`.
- `cameras:` with one templated example using `${FRIGATE_RTSP_PASSWORD}` and a placeholder
  IP, plus a comment explaining how to add more. Mark the exact count/IPs as TODO at
  implement time.
- `detectors:` cpu default (no `ov`/`cuda` block since CPU-only).
- `record:` enabled → `/media`, with a `retain` policy.
- A header comment stating the config is rendered from env at start and that real
  cameras/credentials live only in the SOPS Secret + the resolved file on the PVC.

### 3. `flux/apps/home-assistant/ingress.yaml` (EDIT — append a Tailscale Ingress)

Append a third Ingress `frigate` mirroring the zigbee2mqtt one: `ingressClassName: tailscale`,
`tls.hosts: [frigate]`, backend Service `frigate:8971`. No rule host. The device name `frigate`
is not currently taken on the tailnet (the nine-device list in AGENTS.md has none named
`frigate`), so no `-1` suffix collision expected — confirm in the Tailscale admin console at
apply time.

### 4. `flux/apps/home-assistant/network-policy.yaml` (EDIT — two changes)

a) Policy `mqtt` — add an ingress rule admitting `fromEndpoints: app: frigate` on 1883/tcp,
   alongside the existing zigbee2mqtt rule.
b) Append a new policy `frigate`:
   - `endpointSelector: app: frigate`
   - ingress: `fromEndpoints: io.kubernetes.pod.namespace: tailscale` on 8971/tcp (tailnet
     proxy is the only intended caller) + `host`/`remote-node`/`health` for kubelet probes.
   - egress:
     - kube-dns (53 udp+tcp).
     - `toEndpoints: app: mqtt` on 1883/tcp (publish to Mosquitto).
     - `toCIDRSet: 192.168.0.0/16` and `10.0.0.0/8` on tcp/554 (RTSP to LAN cameras). Use
       `toCIDRSet` not `toEntities: world` (world would include the tailnet/public internet;
       cameras are LAN-only). Include both v4 ranges because the home LAN is 192.168.0.0/24
       and the cluster node network is 10.200.0.0/24 (10.0.0.0/8 covers it). Note: tighten
       to exact camera IPs once known.

### 5. `flux/apps/home-assistant/mqtt.yaml` (EDIT — add frigate ACL user)

In the ConfigMap `mosquitto-config` ACL, add:
```
user frigate
topic readwrite frigate/#
```
Frigate publishes to `frigate/<camera>/...` discovery + state topics and HA subscribes.
Keep it scoped to `frigate/#` (not `#` like the `homeassistant` user) — least privilege.

### 6. `flux/apps/home-assistant/frigate-secret-sops.yaml` (NEW — SOPS Secret)

Create with `stringData:` keys:
- `frigate-mqtt-password`: the Mosquitto password for the `frigate` user (plaintext here,
  encrypted by SOPS; the mosquitto password file needs the *hash* — see step 7).
- `frigate-rtsp-password`: the RTSP password for the cameras (or a shared camera account).

Must be named `frigate-secret-sops.yaml` to match `.sops.yaml` `path_regex: .*-sops\.yaml$`
and use `stringData:` (matches `encrypted_regex: ^(data|stringData|secrets)$`). Encrypt with
`sops -e -i` using the two PGP recipients in `.sops.yaml`. Add to `kustomization.yaml`.

### 7. `flux/apps/home-assistant/mqtt-passwords-sops.yaml` (EDIT — add frigate hash)

The Mosquitto password file format is `<user>:<bcrypt-hash>`. The existing `passwords` key
holds `homeassistant:...` and `zigbee2mqtt:...`. Append `frigate:<hash-of-frigate-mqtt-password>`.

**This requires care**: the SOPS file holds the *password file blob* under `stringData.passwords`,
so editing it means: decrypt → append the new hashed line → re-encrypt with `sops -e -i`.
Generate the hash with `mosquitto_passwd` (or `htpasswd -bnB`). The plaintext the Frigate pod
receives (from the new Secret in step 6) must match this hash. **Do not** put the plaintext
password into the mosquitto password file — only the hash.

### 8. `flux/apps/home-assistant/kustomization.yaml` (EDIT — register new files)

Add `- frigate.yaml`, `- frigate-secret-sops.yaml` to the `resources:` list. The `ks.yaml`
already has the SOPS `decryption` block and `dependsOn: tailscale`, so no KS change needed.

## Out of scope

- NVIDIA GPU acceleration (explicitly declined; CPU-only).
- A new namespace or per-app Flux Kustomization (reusing home-assistant's).
- Public HTTPRoute / SSO (tailnet-only).
- A Google Coral / Edge TPU detector (none exists on any node).
- Home Assistant integration config (done in HA UI: add the Frigate MQTT discovery + the
  Frigate integration pointing at the tailnet hostname). The plan only delivers the infra.

## Risks / gotchas

- **Frigate image runs as root by default.** The HA namespace is PSA `privileged`, so it's
  admissible, but `runAsNonRoot: true` is the repo norm. Test whether the official image
  honors a non-root uid with writable `/config`/`/media` (fsGroup should handle it). If the
  image refuses non-root, fall back to running as root with `runAsNonRoot: false` and document
  why (matching home-assistant/zigbee2mqtt's privileged exception rationale).
- **`shmSize`** is a pod field that some PSA profiles restrict; `privileged` allows it, so fine
  here. Without adequate shm, Frigate detection fails silently with shared-memory errors.
- **CPU-only decode** with multiple cameras will saturate w-1's CPU. Start with sub-streams
  (low-res) for detection and only record the main stream; tune `resources.limits.cpu` at apply.
- **Credential substitution**: verify Frigate's env-var templating in `config.yml` (recent
  Frigate supports `{{ env.MQTT_PASSWORD }}`-style or environment section). If unsupported,
  the init-container `envsubst` fallback is mandatory to keep creds out of git.
- **Tailnet device name `frigate`**: confirm it's free in the Tailscale admin console before
  apply (a collision silently appends `-1`).
- **Mosquitto password hash**: the password file uses bcrypt; the plaintext in the Frigate
  Secret must hash-match the line appended to `mqtt-passwords-sops.yaml`. Test auth with
  `mosquitto_pub`/`mosquitto_sub` from a debug pod before declaring done.
- **big-pool is w-1-only, 1 replica**: w-1 down takes Frigate (and the whole HA stack) with
  it; w-1 cannot be drained while the PVCs exist (`block-if-contains-last-replica`). Same
  constraint as the rest of the HA stack — not new, but Frigate inherits it.

## Validation (at implement time)

1. `kubectl -n home-assistant get pvc frigate-config frigate-media` — both Bound.
2. `kubectl -n home-assistant get sts frigate` — Ready 1/1; pod logs show "Frigate started"
   and an MQTT connection to mosquitto (no auth error).
3. MQTT auth: from a debug pod in the namespace, `mosquitto_sub -h mosquitto -p 1883 -u frigate
   -P <secret> -t 'frigate/#'` — should connect and see discovery messages once a camera is
   configured.
4. `kubectl -n home-assistant get ingress frigate` — ADDRESS shows `frigate.<tailnet>.ts.net`.
5. Cilium: `hubble observe --from-pod home-assistant/frigate --to-port 554` shows RTSP
   reaching cameras (once configured); `--to-port 1883` shows MQTT to mosquitto.
6. HA: add the Frigate integration via the tailnet URL; confirm camera entities appear.
7. Network policy: confirm `kubectl -n home-assistant exec frigate -- nslookup mosquitto`
   resolves and `curl` to a camera IP:554 is allowed while egress to public internet is dropped
   (hubble: no `toEntities: world` verdicts for frigate).
8. Backups: `kubectl -n longhorn-system get recurringjob home-assistant-backup` still lists
   the group; the two new PVs carry the matching label so they're included.

## Open items for implementer

- Fill in the real Frigate image tag + digest (latest stable).
- Fill in camera count + RTSP IPs in the ConfigMap template (user to provide).
- Decide `frigate-media` size (100Gi starting point — expand later).
- Resolve the credential-substitution mechanism (native Frigate env templating vs.
  init-container `envsubst`).
- Generate the bcrypt hash for the frigate MQTT password and append to the mosquitto password
  file Secret.
- Confirm `frigate` is free on the tailnet before applying the Ingress.
