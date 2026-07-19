# Application Index

## Externally Accessible (Public)

| App | Hostname(s) | Backend | Notes |
|-----|-------------|---------|-------|
| authentik | `auth.yewolf.fr` | `ak-outpost-proxy:9000` | SSO provider itself |
| vaultwarden | `vaultwarden.hackcorp.net`, `vaultwarden.yewolf.fr` | `vaultwarden:8080` | |
| woodpecker | `woodpecker.yewolf.fr` | `woodpecker-server:80` | CI/CD |
| stirlingpdf | `pdf.hackcorp.net`, `pdf.yewolf.fr` | keda interceptor | Scale-to-zero |
| pterodactyl | `panel.yewolf.fr` | `pterodactyl-panel:80` | Game server panel |
| portfolio | `yewolf.fr`, `portfolio.hackcorp.net` | keda interceptor | Scale-to-zero |
| joplin | `joplin.yewolf.fr`, `joplin.hackcorp.net` | `joplin:80` | |
| cyberchef | `kebab.hackcorp.net`, `kebab.yewolf.fr` | keda interceptor | Scale-to-zero |
| capsule | `capsule.hackcorp.net`, `capsule.yewolf.fr` | keda interceptor | Scale-to-zero |
| home-assistant | `ha.yewolf.fr` | `home-assistant:8080` | |
| paperless | `paperless.yewolf.fr` | `paperless:8000` | OIDC config in-app (not route-level) |
| registry | `registry.yewolf.fr` | `harbor:80` | Harbor container registry |
| album (immich) | `album.yewolf.fr` | `immich-server:2283` | Photo gallery |
| rustfs console | `rustfs.yewolf.fr` | `rustfs-console:9001` | |
| rustfs artifacts | `artifacts.yewolf.fr` | `rustfs:9000` | |
| jellyfin | `jellyfin.yewolf.fr` | `jellyfin:80` | Media server |
| jellyseerr | `jellyseerr.yewolf.fr` | `jellyseerr:80` | |
| stalwart web | `stalwart.yewolf.fr`, `autoconfig.yewolf.fr`, `autodiscover.yewolf.fr`, `mta-sts.yewolf.fr`, `autoconfig.hackcorp.net`, `autodiscover.hackcorp.net`, `mta-sts.hackcorp.net` | `stalwart-primary:80` | Email server web/config |
| stalwart secondary | `stalwart-secondary.yewolf.fr` | `stalwart-secondary:80` | |
| roundcube | `mail.yewolf.fr`, `mail.hackcorp.net` | `roundcube:80` | Webmail |
| grafana | `grafana.yewolf.fr`, `grafana.hackcorp.net` | `kube-prom-stack-grafana:80` | OIDC config in-app |
| umami | `umami.yewolf.fr` | `umami:3000` | Analytics |
| uptime-kuma | `uptime-aurelien.yewolf.fr` | `uptime-kuma:3001` | |
| flux-webhook | `flux-webhook.hackcorp.net`, `flux-webhook.yewolf.fr` | `notification-controller:80` | |
| saubian | `saubian.yewolf.fr` | `saubian-tailscale-service:8080` | Tailscale subnet router |

### Public TCP (non-HTTP)

| App | Port(s) | Protocol |
|-----|---------|----------|
| portfoliosh | TCP 22 | SSH |
| syncthing sync | TCP 22000 | Syncthing relay |
| mqtt | TCP 1883 | MQTT (TLS terminated) |
| stalwart email | TCP 25, 465, 587, 143, 993, 4190 | SMTP/Submission/SMTPS/IMAP/IMAPS/Sieve |

---

## Externally Accessible via Authentik SSO

Routed directly to each app's Service; a kgateway `TrafficPolicy` on each `HTTPRoute` calls out to
`ak-outpost-proxy:9000` (`/outpost.goauthentik.io/auth/envoy`) via the `authentik-ext-auth`
`GatewayExtension`. Authentik providers for these apps run in Forward Auth (domain level) mode,
cookie domain `yewolf.fr`. Full design, gotchas, and how to add an app:
[authentik-extauth.md](authentik-extauth.md).

| App | Hostname | Backend | Namespace |
|-----|----------|---------|-----------|
| radarr | `radarr.yewolf.fr` | `radarr:80` | servarr |
| sonarr | `sonarr.yewolf.fr` | `sonarr:80` | servarr |
| bazarr | `bazarr.yewolf.fr` | `bazarr:80` | servarr |
| prowlarr | `prowlarr.yewolf.fr` | `prowlarr:80` | servarr |
| flaresolverr | `flaresolverr.yewolf.fr` | `flaresolverr:80` | servarr |
| dl | `dl.yewolf.fr` | youtube downloader (`yt-dlp-webui:80`) | ytdlp |
| syncthing web | `syncthing.yewolf.fr` | `syncthing:8384` | syncthing |

> `qbittorrent` moved to Tailscale-only (dashboard router below); `joal` moved to its own Tailscale host.

---

## Internal / Tailscale-Only

### Tailscale

| App | Hostname | Backend |
|-----|----------|---------|
| radar | `radar.tail5ec535.ts.net` | `radar:9280` |
| pgadmin | `pgadmin.tail5ec535.ts.net` | keda interceptor (scale-to-zero) |
| phpmyadmin | `phpmyadmin.tail5ec535.ts.net` | keda interceptor (scale-to-zero) |
| dashboard router | `dashboard.tail5ec535.ts.net` | `caddy:80` (namespace `dashboard`) |
| joal / Rustatio | `joal.tail5ec535.ts.net` | `joal.servarr:80` — root-anchored SPA, own host (linked from dashboard) |

#### Dashboard router (single hostname, path-routed)

One Caddy pod behind one Tailscale Ingress. Static dashboard at `/`, each app under a
path. `applications/software/home1/dashboard/`.

| Path | Backend | Prefix handling | Notes |
|------|---------|-----------------|-------|
| `/` | Caddy `file_server` | — | static links page |
| `/scrutiny/` | `scrutiny.scrutiny:80` | kept | emits absolute links — app base-path `SCRUTINY_WEB_LISTEN_BASEPATH=/scrutiny` |
| `/esphome/` | `esphome.home-assistant:6052` | stripped | relative assets (HA-ingress design), no app config |
| `/zigbee2mqtt/` | `zigbee2mqtt.home-assistant:8080` | stripped | relative assets, no app config |
| `/qbittorrent/` | `qbittorrent.servarr:80` | stripped | enable "Reverse proxy support" in WebUI; needs `dashboard` in servarr netpol |
| `/music/` | `music-assistant-server.home-assistant:8095` | stripped | relative assets; websocket derives from location |

joal/Rustatio is **not** in the router — it's a root-anchored SPA (absolute `/assets` +
absolute API paths, no base-path option), so it has its own Tailscale hostname
(`joal.tail5ec535.ts.net`) and the dashboard just links to it.

### Internal-Only (No External Exposure)

| App | Notes |
|-----|-------|
| prometheus | Monitoring |
| alertmanager | Monitoring |
| blackbox-exporter | Monitoring |
| postgresql | Database (ClusterIP) |
| mariadb | Database (ClusterIP) |
| ytdlp | `yt-dlp-webui:80` (ClusterIP) |
| satisfactory | Game server (ClusterIP) |
| music-assistant | Home Assistant addon — now reachable via dashboard router `/music` |
| snapserver | Home Assistant addon |
| zigbee2mqtt | Home Assistant addon — now reachable via dashboard router `/zigbee2mqtt` |
| frigate | Home Assistant addon |
| smart-clock | Home Assistant addon |
| piper | Home Assistant addon |
| stt | Home Assistant addon |
| cert-manager | Infrastructure |
| k8up | Backup operator |
| kyverno | Policy engine |
| falco | Runtime security |
| keda | Autoscaler |
| metrics-server | Infrastructure |
| runtimeclasses | Config only |

---

**Gateway**: kgateway terminates TLS for `*.yewolf.fr`, `*.hackcorp.net`, `yewolf.fr`, `hackcorp.net`.  
**Scale-to-zero**: portfolio, capsule, cyberchef, stirlingpdf, pgadmin, and phpmyadmin use KEDA `HTTPScaledObject`.
