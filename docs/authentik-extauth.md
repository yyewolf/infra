# Authentik SSO via kgateway ExtAuth

How public apps are protected with single sign-on. This replaced the older setup where a
single `oauth-proxy` HTTPRoute in the `authentik` namespace proxied every SSO host through
the `ak-outpost-proxy` reverse proxy.

## Overview

Each protected app is now routed **directly to its own Service**. Authentication is enforced
by kgateway's **ExtAuth** filter, which calls out to the authentik proxy outpost in
**forward-auth** mode for every request. If the request is unauthenticated the outpost returns
a redirect to the authentik login; once a valid session cookie is present the request is
forwarded to the app.

```
                    ┌─────────────────────────────────────────────┐
  browser ─────────▶│ kgateway (Gateway "kgateway", listener https)│
                    │                                             │
                    │   HTTPRoute radarr  ──(TrafficPolicy)──┐     │
                    └────────────────────────────────────────┼─────┘
                                                             │ extAuth check
                                                             ▼
                              GatewayExtension authentik-ext-auth
                                 (httpService → ak-outpost-proxy:9000
                                  /outpost.goauthentik.io/auth/envoy)
                                                             │
                              allow ──▶ forward to radarr Service
                              deny  ──▶ 302 to auth.yewolf.fr login
```

## Components

All paths are relative to the repo root.

| Resource | Location | Purpose |
|----------|----------|---------|
| `GatewayExtension/authentik-ext-auth` | `applications/backbone/gateway/kgateway-ext/gateway-extension-authentik.yaml` | ExtAuth extension → `ak-outpost-proxy.authentik:9000`, pathPrefix `/outpost.goauthentik.io/auth/envoy` |
| `ReferenceGrant` (kgateway ns) | `applications/backbone/gateway/kgateway-ext/reference-grant.yaml` | Lets app-namespace `TrafficPolicy` objects reference the GatewayExtension cross-namespace |
| `ReferenceGrant` (authentik ns) | `applications/software/cluster/authentik/reference-grant.yaml` | Lets the GatewayExtension (and app HTTPRoutes) reach the `ak-outpost-proxy` Service |
| Per-app `HTTPRoute` + `TrafficPolicy` | `applications/software/home1/{servarr,syncthing,ytdlp}/…` | Route host → real Service, attach `extAuth.extensionRef` |

Each app's `TrafficPolicy` is what turns auth on:

```yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: TrafficPolicy
metadata:
  name: radarr-ext-auth
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: radarr
  extAuth:
    extensionRef:
      name: authentik-ext-auth
      namespace: kgateway
```

There is **no** per-app `/outpost.goauthentik.io` HTTPRoute. Authentik's `/auth/envoy` handler
services the `start` / `callback` sub-paths inline as part of the ext_authz response, so a
separate route for them is unnecessary.

## Authentik provider configuration

Every protected app has a **Proxy Provider** that must be in:

- **Mode:** `Forward auth (domain level)` (`forward_domain`)
- **Cookie domain:** `yewolf.fr`

Domain-level mode is what makes the session cookie shared across every `*.yewolf.fr` app —
i.e. true single sign-on — and it is what makes authentik reconstruct the correct post-login
return URL. Providers are attached to the `Proxy` outpost (`ak-outpost-proxy`).

> ⚠️ In `proxy` or `forward_single` mode the post-auth redirect reconstructs a bogus
> `/outpost.goauthentik.io/auth/envoy/...` path and the app returns a 404 loop. Domain level
> is required for this ExtAuth wiring.

Flip a provider via the API (see [authentik admin access](#appendix-authentik-admin-api)):

```bash
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X PATCH "http://localhost:9000/api/v3/providers/proxy/<pk>/" \
  -d '{"mode":"forward_domain","cookie_domain":"yewolf.fr"}'
```

## Gotcha: ExtAuth response header case

The header lists in the GatewayExtension's `authorizationResponse` **must be lowercase**:

```yaml
authorizationResponse:
  headersToBackend:        # copied to the app on allow
  - x-authentik-uid
  - x-authentik-username
  - x-authentik-name
  - x-authentik-email
  - x-authentik-groups
  - x-authentik-entitlements
  headersToClient:         # copied to the browser on deny (302)
  - set-cookie
  - location
  headersToClientOnSuccess:
  - set-cookie
```

Envoy normalises header names to lowercase and matches this allow-list case-sensitively. If
`Set-Cookie` is capitalised it is silently dropped from the deny response, the outpost never
seeds its session cookie, and the login callback fails with a `400 Bad Request` — the outpost
logs `mismatched session ID … should: ""`.

## Protected apps

See the "Externally Accessible via Authentik SSO" table in [app-index.md](app-index.md).

`flaresolverr` is included. It is also used as a scraping backend by the *arr apps — those
must call it via the in-cluster Service (`http://flaresolverr`), **not** the public
`flaresolverr.yewolf.fr` host, otherwise the internal calls hit the login wall.

## Adding a new SSO-protected app

1. Create/point an authentik **Proxy Provider** at the app, mode `forward_domain`, cookie
   domain `yewolf.fr`, attached to the `Proxy` outpost. Bind an Application with the access
   policies you want.
2. Add an `HTTPRoute` for the host → the app Service (parented to the `kgateway` Gateway,
   `sectionName: https`).
3. Add a `TrafficPolicy` targeting that HTTPRoute with `extAuth.extensionRef` →
   `authentik-ext-auth` / `kgateway` (see snippet above).
4. If the app is in a new namespace, add that namespace to the `from` list of the authentik
   `ReferenceGrant` (`applications/software/cluster/authentik/reference-grant.yaml`) and the
   kgateway `ReferenceGrant`.

## Appendix: authentik admin API

Use the write-capable kubeconfig `terraform/output/kubeconfig`. Mint a token from an
authentik-server pod, then reach the API on **port 9000** inside the pod:

```bash
kubectl exec -n authentik <authentik-server-pod> -- ak shell -c \
  "from authentik.core.models import Token,User,TokenIntents; \
   u=User.objects.filter(username='akadmin').first(); \
   t,_=Token.objects.update_or_create(identifier='admin-cli', \
       defaults={'user':u,'intent':TokenIntents.INTENT_API,'expiring':False}); \
   print('KEY='+t.key)"
```

Useful endpoints: `providers/proxy/`, `outposts/instances/`,
`core/applications/?superuser_full_list=true`.
