set -eu

# ---------------------------------------------------------------- configuration
: "${VCLUSTER_NAME:=uctf-mgmt}"
# uctf-mgmt.uctf, not .svc: the vcluster's serving certificate carries
# `uctf-mgmt` and `uctf-mgmt.uctf` as SANs and stops there, so the FQDN form
# fails verification.
: "${VCLUSTER_SERVER:=https://uctf-mgmt.uctf:443}"
: "${VCLUSTER_SECRET_DIR:=/vc}"
: "${HOST_NAMESPACE:=uctf}"
: "${GATEWAY_NAME:=envoy-gateway}"
: "${GATEWAY_NAMESPACE:=envoy-gateway-system}"
: "${GATEWAY_SECTION:=unspecified-tls}"
# The port on the inner gateway's Service. Both of them publish the gateway's
# TLS listener on 443, the same port tlsroute-system.yaml's hand-written routes
# already target.
: "${BACKEND_PORT:=443}"
: "${INTERVAL:=30}"
: "${CALL_TIMEOUT:=60}"
: "${VC_KUBECONFIG:=/tmp/vc.kubeconfig}"
: "${HOST_KUBECONFIG:=}"
: "${DRY_RUN:=}"

MANAGED_LABEL="tlsroute-sync.uctf.io/managed"
SRC_NS_ANN="tlsroute-sync.uctf.io/source-namespace"
SRC_NAME_ANN="tlsroute-sync.uctf.io/source-name"
W=/tmp/work
mkdir -p "$W"

# Wrapped in `timeout` because nothing here restarts the pod when a call hangs:
# a wedged connection to either API server would stop the loop for good rather
# than failing the pass and being retried.
#
# It is `timeout` and not kubectl --request-timeout, which cannot be used on
# the host calls at all. That flag registers as an explicit config override, so
# client-go stops treating the configuration as the default one and never
# reaches its in-cluster fallback: kubectl then addresses localhost:8080 and
# every call fails with a connection refused, with nothing in the message to
# suggest the flag caused it. The external timer is also the stronger of the
# two — a request timeout does not bound a DNS lookup or a TLS handshake that
# never returns.
vc()   { timeout "$CALL_TIMEOUT" kubectl --kubeconfig="$VC_KUBECONFIG" "$@"; }
host() {
  if [ -n "$HOST_KUBECONFIG" ]; then timeout "$CALL_TIMEOUT" kubectl --kubeconfig="$HOST_KUBECONFIG" "$@"
  else timeout "$CALL_TIMEOUT" kubectl "$@"; fi
}

log() { echo "$(date -u +%H:%M:%S) $*"; }

# vcluster's own translate.SafeConcatName, reimplemented so the names this
# writes match the ones the syncer picks in the same namespace: join with "-",
# and if that is longer than 63 characters keep the first 52 and append 10 hex
# digits of the full string's sha256.
safe_name() {
  _n=$1
  if [ ${#_n} -gt 63 ]; then
    printf '%s-%s' "$(printf %s "$_n" | cut -c1-52)" \
                   "$(printf %s "$_n" | sha256sum | cut -c1-10)"
  else
    printf %s "$_n"
  fi
}

# ---------------------------------------------------------------- vc kubeconfig
if [ -d "$VCLUSTER_SECRET_DIR" ]; then
  # Written out rather than assembled with `kubectl config set-cluster`, which
  # rewrites an absolute --certificate-authority into a path relative to the
  # kubeconfig's own directory. That still resolves, but it resolves to
  # something nobody reading the file would expect.
  #
  # The paths are left as paths, not embedded: a rotated client certificate is
  # then picked up on the next call instead of at the next restart.
  cat >"$VC_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: vc
  cluster:
    server: $VCLUSTER_SERVER
    certificate-authority: $VCLUSTER_SECRET_DIR/certificate-authority
users:
- name: vc
  user:
    client-certificate: $VCLUSTER_SECRET_DIR/client-certificate
    client-key: $VCLUSTER_SECRET_DIR/client-key
contexts:
- name: vc
  context:
    cluster: vc
    user: vc
current-context: vc
EOF
fi

# ---------------------------------------------------------------- rendering
render_route() {
  jq -c \
    --arg ns "$1" --arg name "$2" --arg hostName "$3" \
    --arg hostNs "$HOST_NAMESPACE" \
    --arg gwName "$GATEWAY_NAME" --arg gwNs "$GATEWAY_NAMESPACE" \
    --arg gwSection "$GATEWAY_SECTION" \
    --argjson backendPort "$BACKEND_PORT" \
    --arg label "$MANAGED_LABEL" --arg srcNsAnn "$SRC_NS_ANN" --arg srcNameAnn "$SRC_NAME_ANN" \
    --slurpfile svc "$W/host-svc.json" '
    # Where a Service created inside the vcluster landed on the host. Read off
    # the annotations the syncer stamps rather than recomputed, because the
    # names are truncated and hashed past 63 characters and a route pointing at
    # a name that does not exist is accepted and then silently blackholes.
    ($svc[0].items
     | map(select(.metadata.annotations["vcluster.loft.sh/object-name"] != null))
     | map({ key: "\(.metadata.annotations["vcluster.loft.sh/object-namespace"])/\(.metadata.annotations["vcluster.loft.sh/object-name"])",
             value: .metadata.name })
     | from_entries) as $svcmap
    | (.items[] | select(.metadata.namespace == $ns and .metadata.name == $name)) as $r
    # The route keeps its own backendRefs and its own gateway inside the
    # vcluster; what comes out here is the hop in front of that. Each inner
    # Gateway is fronted by a Service of the same name in the same namespace
    # (gateway-01/gateway-01, gateway-system/gateway-system), so the parentRef
    # is what names the backend out here.
    | [ $r.spec.parentRefs[]?
        | select((.kind // "Gateway") == "Gateway")
        | { ns: (.namespace // $ns), name: .name }
        | select($svcmap["\(.ns)/\(.name)"] != null)
        | { ref: "\(.ns)/\(.name)", service: $svcmap["\(.ns)/\(.name)"] } ] as $parents
    | if ($parents | length) == 0 then
        { skip: "no parentRef naming a Gateway with a Service synced to the host" }
      else
      { extra: ($parents[1:] | map(.ref)),
        object:
        { apiVersion: "gateway.networking.k8s.io/v1",
          kind: "TLSRoute",
          metadata: {
            name: $hostName,
            namespace: $hostNs,
            labels: { ($label): "true" },
            annotations: { ($srcNsAnn): $ns, ($srcNameAnn): $name } },
          spec: {
            hostnames: $r.spec.hostnames,
            parentRefs: [ { group: "gateway.networking.k8s.io", kind: "Gateway",
                            name: $gwName, namespace: $gwNs }
                          + (if $gwSection == "" then {} else { sectionName: $gwSection } end) ],
            rules: [ { backendRefs: [ { group: "", kind: "Service",
                                        name: $parents[0].service,
                                        port: $backendPort } ] } ] } } }
      end' "$W/src-routes.json"
}

# ---------------------------------------------------------------- one pass
sync_once() {
  # Every fetch is checked by hand rather than left to `set -e`: this function
  # is called from a `||` so errexit does not apply inside it, and a half-read
  # source would look like "nothing to sync" and prune every route on the host.
  vc get tlsroutes.gateway.networking.k8s.io -A -o json >"$W/src-routes.json" || {
    log "ERROR: cannot list TLSRoutes in the vcluster"; return 1; }
  host get services -n "$HOST_NAMESPACE" -o json >"$W/host-svc.json" || {
    log "ERROR: cannot list Services in $HOST_NAMESPACE"; return 1; }

  : >"$W/desired.jsonl"
  : >"$W/want-routes.txt"

  jq -r '
    .items[]
    | .metadata.namespace as $ns | .metadata.name as $n
    # No hostnames is "every SNI" in the Gateway API, and at the edge that
    # would take over every connection the terminate listeners do not claim.
    # The catch-all is a deliberate, repo-managed decision, not something a
    # tenant gets to make by omission.
    | if ((.spec.hostnames // []) | length) == 0 then "\($ns)\t\($n)\tno hostnames"
      else "\($ns)\t\($n)\tok" end' "$W/src-routes.json" >"$W/candidates.tsv" || {
    log "ERROR: cannot read the TLSRoute list"; return 1; }

  while IFS='	' read -r ns name state; do
    [ -n "${ns:-}" ] || continue
    if [ "$state" != ok ]; then
      log "skip tlsroute $ns/$name: $state"
      continue
    fi
    hn=$(safe_name "${name}-x-${ns}-x-${VCLUSTER_NAME}")
    out=$(render_route "$ns" "$name" "$hn") || { log "ERROR rendering $ns/$name"; return 1; }
    skip=$(printf %s "$out" | jq -r '.skip // empty')
    if [ -n "$skip" ]; then
      log "skip tlsroute $ns/$name: $skip"
      continue
    fi
    # A route attached to two inner gateways cannot become one route out here:
    # two backendRefs would load-balance the same SNI across two Envoys rather
    # than reach both. The first parent wins and the rest are named in the log.
    extra=$(printf %s "$out" | jq -r '.extra | join(", ")')
    [ -z "$extra" ] || log "note tlsroute $ns/$name: ignoring extra parentRef(s) $extra"
    printf %s "$out" | jq -c '.object' >>"$W/desired.jsonl"
    printf '%s\n' "$hn" >>"$W/want-routes.txt"
  done <"$W/candidates.tsv"

  if [ -n "$DRY_RUN" ]; then
    log "would apply $(wc -l <"$W/want-routes.txt" | tr -d ' ') route(s)"
    jq -s '.' "$W/desired.jsonl"
  elif [ -s "$W/desired.jsonl" ]; then
    # Server-side apply: this pod owns the fields it sets and nothing else, so
    # a hand edit to a synced route is reverted on the next pass instead of
    # merged into an ever-growing last-applied annotation.
    jq -s '{ apiVersion: "v1", kind: "List", items: . }' "$W/desired.jsonl" \
      | host apply --server-side --force-conflicts \
                   --field-manager=tlsroute-sync -f - >/dev/null || {
        log "ERROR: apply failed"; return 1; }
  fi

  prune tlsroutes.gateway.networking.k8s.io "$W/want-routes.txt" || return 1

  log "in sync: $(wc -l <"$W/want-routes.txt" | tr -d ' ') route(s)"
}

# Anything carrying the managed label that this pass did not ask for is gone
# from the vcluster (or newly ineligible) and goes with it. The label is what
# keeps the repo-managed routes in this namespace out of reach.
prune() {
  _kind=$1; _want=$2
  host get "$_kind" -n "$HOST_NAMESPACE" -l "$MANAGED_LABEL=true" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' >"$W/have.txt" 2>/dev/null || {
    log "ERROR: cannot list $_kind on the host"; return 1; }
  # FILENAME, not the usual NR==FNR: when nothing is wanted the first file is
  # empty, NR==FNR then holds for every line of the second one, and the pass
  # that should have pruned everything prunes nothing instead.
  awk -v want_file="$_want" '
    FILENAME == want_file { want[$0]=1; next }
    $0 != "" && !($0 in want)' "$_want" "$W/have.txt" \
  | while read -r n; do
      log "prune $_kind/$n"
      [ -n "$DRY_RUN" ] || host delete "$_kind" -n "$HOST_NAMESPACE" "$n" --ignore-not-found >/dev/null
    done
}

log "syncing TLSRoutes from $VCLUSTER_NAME into $HOST_NAMESPACE every ${INTERVAL}s"
while :; do
  sync_once || log "pass failed, retrying in ${INTERVAL}s"
  [ -z "$DRY_RUN" ] || break
  sleep "$INTERVAL"
done
