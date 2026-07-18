# Pod hardening — exceptions

Most workloads in this repo were hardened to run rootless and/or with a read-only
root filesystem, dropped capabilities and a `RuntimeDefault` seccomp profile
(see the `harden:` commits). This file records the workloads that **cannot** reach
that baseline and why, so the gaps are intentional and reviewable.

Two constraints drive every exception below:

- **sysbox can't help.** `runtimeClassName: sysbox-runc` gives rootless-on-host for
  images that must be root *inside* the container, but it does **not** support
  `hostNetwork`, host PID/IPC, or host **device** passthrough.
- **sysbox + shared hostPath breaks ownership.** With `hostUsers: false` each pod
  gets its own user-namespace sub-UID range, so apps that share a hostPath (the
  servarr `/tank` tree) would lose access to each other's files.

## Left privileged / host-access (no container hardening applied)

| Workload | Why it needs host access | Blocker |
|---|---|---|
| `software/home1/scrutiny` | reads raw-disk SMART; `privileged`, `SYS_RAWIO`/`SYS_ADMIN`, hostPath `/dev` + `/run/udev` | host block devices — sysbox can't passthrough devices |
| `home-assistant/addons/zigbee2mqtt` | `privileged`, hostPath `/dev/ttyUSB0` (Zigbee USB dongle) | USB device passthrough |
| `home-assistant/addons/esphome-builder` | `privileged` + `hostNetwork` (device flashing, mDNS) | hostNetwork + privileged |
| `home-assistant/addons/music-assistant` | `privileged` + `SYS_ADMIN` + `hostNetwork` (mDNS discovery, snapcast) | hostNetwork + privileged |
| `backbone/tailscale` (DaemonSet) | mesh VPN: `privileged`, `hostNetwork`, `/dev/net/tun` | core host networking |
| `backbone/sysbox-deploy` (DaemonSet) | installs the sysbox runtime onto nodes; mounts host filesystem | must be privileged by design |

## Kept host access / special runtime, but hardened where tolerated

Added `allowPrivilegeEscalation: false` + `seccompProfile: RuntimeDefault` (and
dropped caps where the app allows) while keeping the host feature they require:

| Workload | Kept | Hardened |
|---|---|---|
| `servarr` nvidia-device-plugin | `runtimeClassName: nvidia`, hostPath device-plugins | already had no-priv-esc + drop ALL |
| `servarr` jellyfin | `runtimeClassName: nvidia` (GPU transcode) + shared `/tank` hostPath | no-priv-esc + seccomp (can't sysbox: one runtimeClass + shared hostPath) |
| `servarr` sonarr/radarr/prowlarr/bazarr | LSIO (s6, must init as root) + shared `/tank` hostPath | no-priv-esc + seccomp |
| `servarr/torrent` gluetun | VPN: `NET_ADMIN` + tun | **none** — `NET_ADMIN` only; seccomp + no-priv-esc omitted (OpenVPN auth was unreliable under them, verified live) |
| `servarr/torrent` qbittorrent | LSIO + shared hostPath | no-priv-esc + seccomp |
| `servarr/torrent` rustatio | shared hostPath; PUID/gosu entrypoint chowns `/app`+`/data` | no-priv-esc + seccomp (caps kept — needs CHOWN/SETUID) |
| `home-assistant/addons/snapserver` | `hostNetwork` (audio streaming/discovery) | no-priv-esc + seccomp |

## Deferred — sysbox candidates pending verification

`frigate`, `piper` (LSIO/s6), and `satisfactory` (rootful game server) have no host
device/network needs and could run rootless-on-host under `sysbox-runc`. They were
**not** moved because their existing persistent data is root-owned and, depending on
whether this cluster's sysbox chowns k8s volumes or uses idmapped mounts, the
containers could lose access to it until the data is chowned into the sysbox sub-UID
range. For now they run on the normal runtime with `allowPrivilegeEscalation: false`
+ `seccompProfile: RuntimeDefault`. To promote later: verify sysbox's volume id-map
behaviour on a throwaway PVC, migrate data ownership if needed, then add
`runtimeClassName: sysbox-runc` (Kyverno `sysbox-hostusers-fix` adds `hostUsers: false`).
