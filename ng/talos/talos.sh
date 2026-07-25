#!/usr/bin/env bash
#
# Driver for the ng Talos cluster. Everything it produces is derived from
# cluster.yaml, schematic.yaml, patches/ and nodes/ — all tracked in git — plus
# the encrypted secrets bundle. Nothing lands in out/ that cannot be thrown away
# and regenerated.
#
# Run './talos.sh' with no arguments for the command list.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="$DIR/cluster.yaml"
SCHEMATIC="$DIR/schematic.yaml"
SECRETS="$DIR/secrets-sops-all.yaml"
OUT="$DIR/out"
FACTORY="https://factory.talos.dev"

# Shared with ng/router, which builds its WireGuard peers from the same file.
# Off-LAN nodes take their tunnel key material from here rather than duplicating
# it, so the two ends cannot drift apart.
WG_REGISTRY="$DIR/../wireguard/identities-sops.yaml"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() { echo "==> $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

cfg() { yq -r "$1" "$CLUSTER"; }

node_names() { cfg '.nodes | keys | .[]'; }

node_field() {
    local value
    value="$(cfg ".nodes.\"$1\".$2")"
    [ "$value" = "null" ] && value=""
    printf '%s' "$value"
}

require_node() {
    node_names | grep -qx "$1" ||
        die "unknown node '$1' (have: $(node_names | tr '\n' ' '))"
}

# ------------------------------------------------------------------- wireguard

# Decrypted copy of the identity registry, written under out/ (mode 700) only
# when a node being rendered actually needs it, and removed by the render trap.
WG_PLAIN="$OUT/.wireguard.yaml"

wg_field() {
    yq -r "$1 // \"\"" "$WG_PLAIN"
}

# Emits the wg0 interface for an off-LAN node. Everything sensitive goes
# straight into the patch file — never to stdout, which is a terminal.
emit_wireguard() {
    local n="$1" peer="$2" address="$3" wg_subnet="$4" lan_subnet="$5" mtu="$6"

    local priv pub endpoint port registered
    priv="$(wg_field ".secrets.\"$n\".private_key")"
    port="$(wg_field ".identities.\"$n\".listen_port")"
    registered="$(wg_field ".identities.\"$n\".address")"
    pub="$(wg_field ".identities.\"$peer\".public_key")"
    endpoint="$(wg_field ".identities.\"$peer\".endpoint")"

    [ -n "$priv" ] || die "no private key for '$n' in $WG_REGISTRY — run ./wireguard/gen-identity.sh $n $address/32"
    [ -n "$pub" ] || die "no public key for peer '$peer' in $WG_REGISTRY"

    # The router turns each identity's address into a static route and an
    # allowed-address. If cluster.yaml disagrees with the registry, the node
    # comes up on an address the router drops — a tunnel that handshakes and
    # then carries nothing, which is a miserable thing to debug.
    if [ "${registered%%/*}" != "$address" ]; then
        die "node $n is $address in cluster.yaml but $registered in $WG_REGISTRY — make them agree"
    fi

    echo "      - interface: wg0"
    echo "        mtu: $mtu"
    # /32: the peer's own address is the only thing reachable on-link. Reaching
    # anything else is a routing decision, made explicitly below.
    echo "        addresses:"
    echo "          - $address/32"
    # Talos programs the WireGuard peer from allowedIPs but does not derive
    # routes from it, so both subnets need saying twice — once as crypto
    # routing (what the tunnel will accept and encrypt) and once as kernel
    # routing (what gets sent there at all). No gateway: link-scoped out wg0.
    echo "        routes:"
    echo "          - network: $lan_subnet"
    echo "          - network: $wg_subnet"
    echo "        wireguard:"
    echo "          privateKey: $priv"
    [ -n "$port" ] && echo "          listenPort: $port"
    echo "          peers:"
    echo "            - publicKey: $pub"
    echo "              allowedIPs:"
    echo "                - $lan_subnet"
    echo "                - $wg_subnet"
    # Only dial the peer if the registry says where it is. The home router sits
    # behind the ISP's NAT with no stable endpoint, so it dials us and we learn
    # its address from the handshake; a keepalive from this side would just be
    # packets to nowhere until then.
    if [ -n "$endpoint" ]; then
        echo "              endpoint: $endpoint"
        echo "              persistentKeepaliveInterval: 25s"
    fi
}

# ------------------------------------------------------------------- schematic

# Uploads schematic.yaml and prints the resulting ID. The factory is
# content-addressed, so re-uploading an unchanged file returns the same ID and
# costs nothing but a round trip. Cached so render/iso do not both re-upload.
cmd_schematic() {
    need curl
    local cache="$OUT/schematic-id" hash
    hash="$(sha256sum "$SCHEMATIC" | cut -d' ' -f1)"

    if [ -f "$cache" ] && [ "$(head -n1 "$cache")" = "$hash" ]; then
        tail -n1 "$cache"
        return
    fi

    info "uploading schematic to $FACTORY"
    local id
    id="$(curl -fsSL -X POST --data-binary "@$SCHEMATIC" "$FACTORY/schematics" |
        jq -r '.id')"
    [ -n "$id" ] && [ "$id" != "null" ] || die "factory did not return a schematic ID"

    mkdir -p "$OUT"
    printf '%s\n%s\n' "$hash" "$id" >"$cache"
    printf '%s' "$id"
}

installer_image() {
    printf 'factory.talos.dev/metal-installer/%s:%s' \
        "$(cmd_schematic)" "$(cfg .talos_version)"
}

# ------------------------------------------------------------------------- iso

cmd_iso() {
    need curl
    local id version url path
    id="$(cmd_schematic)"
    version="$(cfg .talos_version)"
    url="$FACTORY/image/$id/$version/metal-amd64.iso"
    path="$OUT/talos-$version-metal-amd64.iso"

    mkdir -p "$OUT"
    if [ -f "$path" ]; then
        info "already downloaded: $path"
    else
        info "downloading $url"
        curl -fL --progress-bar -o "$path.part" "$url"
        mv "$path.part" "$path"
    fi
    echo "$path"
}

# ------------------------------------------------------------------------- usb
#
# One ISO serves all three hosts. It boots straight into maintenance mode and
# never touches local storage, so the same key gets carried from box to box and
# the real install happens over the network in 'apply'.

cmd_usb() {
    local device="${1:-}"
    [ -n "$device" ] || die "usage: $0 usb /dev/sdX"
    [ -b "$device" ] || die "$device is not a block device"

    local name removable
    name="$(basename "$(readlink -f "$device")")"
    [ -e "/sys/block/$name" ] ||
        die "$device looks like a partition, pass the whole disk (e.g. /dev/sdb)"

    removable="$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)"
    if [ "$removable" != "1" ]; then
        echo "WARNING: $device is not flagged removable. This may be an internal disk." >&2
    fi

    local iso
    iso="$(cmd_iso)"

    echo >&2
    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$device" >&2
    echo >&2
    echo "This ERASES $device and writes $(basename "$iso")." >&2
    read -r -p "Type the device path to confirm: " confirm
    [ "$confirm" = "$device" ] || die "aborted"

    info "writing (needs root)"
    sudo dd if="$iso" of="$device" bs=4M status=progress oflag=direct conv=fsync
    sudo sync
    info "done, boot each host from this key in turn"
}

# --------------------------------------------------------------------- secrets

cmd_secrets() {
    need sops
    [ -f "$SECRETS" ] && [ "${1:-}" != "--force" ] &&
        die "$SECRETS already exists. Regenerating orphans the cluster; pass --force if you mean it"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    info "generating cluster PKI and tokens"
    (umask 077 && talosctl gen secrets --output-file "$tmp/secrets.yaml")

    # Named -sops-all so the repo's .sops.yaml encrypts every value. The default
    # -sops rule only covers keys called 'secrets', which would leave the CA
    # private keys sitting in git as plaintext.
    #
    # --filename-override because sops picks its creation rule from the input
    # path, and the input here is a tempfile outside the repo. Without it sops
    # finds no matching rule and refuses.
    sops -e --filename-override "$SECRETS" --output "$SECRETS" "$tmp/secrets.yaml"
    info "wrote $SECRETS"
}

# ---------------------------------------------------------------------- render

# Renders every node, or just the ones named. The subset form exists for
# incremental bring-up: you cannot know a host's install disk until you have
# booted it, so demanding all three up front would block the first one.
cmd_render() {
    need sops
    need yq
    [ -f "$SECRETS" ] || die "no $SECRETS — run '$0 secrets' first"

    local targets=("$@")
    if [ ${#targets[@]} -eq 0 ]; then
        mapfile -t targets < <(node_names)
    else
        for n in "${targets[@]}"; do require_node "$n"; done
    fi

    local name vip gateway subnet subnet6 gateway6 wg_subnet wg_mtu version k8s image
    name="$(cfg .name)"
    vip="$(cfg .network.vip)"
    gateway="$(cfg .network.gateway)"
    subnet="$(cfg .network.subnet)"
    subnet6="$(cfg '.network.subnet6 // ""')"
    gateway6="$(cfg '.network.gateway6 // ""')"
    wg_subnet="$(cfg '.network.wg_subnet // ""')"
    wg_mtu="$(cfg '.network.wg_mtu // 1420')"
    version="$(cfg .talos_version)"
    k8s="$(cfg .kubernetes_version)"

    local prefix="${subnet##*/}"
    local prefix6="${subnet6##*/}"

    for n in "${targets[@]}"; do
        [ -f "$DIR/nodes/$n.yaml" ] || die "cluster.yaml lists $n but nodes/$n.yaml is missing"
        if [ "$(yq -r '.machine.install.disk // ""' "$DIR/nodes/$n.yaml")" = "REPLACE_ME" ]; then
            die "nodes/$n.yaml still says disk: REPLACE_ME — run '$0 disks <ip>' and set the real device"
        fi
    done

    image="$(installer_image)"

    mkdir -p "$OUT/patches"
    chmod 700 "$OUT"

    local plain="$OUT/.secrets.yaml"
    trap 'rm -f "$plain" "$WG_PLAIN"' RETURN
    (umask 077 && sops -d --output "$plain" "$SECRETS")

    # Only decrypt the WireGuard registry if something being rendered needs it.
    for n in "${targets[@]}"; do
        if [ -n "$(node_field "$n" wireguard.peer)" ]; then
            [ -f "$WG_REGISTRY" ] || die "node $n needs WireGuard but $WG_REGISTRY is missing"
            (umask 077 && sops -d --output "$WG_PLAIN" "$WG_REGISTRY")
            break
        fi
    done

    info "generating base configs"
    rm -rf "$OUT/base"
    talosctl gen config "$name" "https://$vip:6443" \
        --with-secrets "$plain" \
        --kubernetes-version "$k8s" \
        --output-types controlplane,worker,talosconfig \
        --output "$OUT/base" \
        --config-patch "@$DIR/patches/common.yaml" \
        --config-patch-control-plane "@$DIR/patches/controlplane.yaml" \
        --config-patch-worker "@$DIR/patches/worker.yaml" \
        --force

    # gen config ships a HostnameConfig document defaulted to 'auto: stable'.
    # It merges rather than being replaced, and Talos rejects a config where
    # both 'auto' and 'hostname' are set — so drop the document entirely and let
    # machine.network.hostname in the per-node patch below be the only source.
    for t in controlplane worker; do
        yq -i 'select(.kind != "HostnameConfig")' "$OUT/base/$t.yaml"
    done

    # Every node's cert covers the VIP and every node address, generated below.
    # Talking to a node directly is how you debug a broken VIP, so leaving those
    # SANs out breaks certificate validation exactly when you need it most.
    # These come from cluster.yaml, so a subset render still produces configs
    # that trust every node.
    for n in "${targets[@]}"; do
        local type address address6 selector patch wg_peer
        type="$(node_field "$n" type)"
        address="$(node_field "$n" address)"
        address6="$(node_field "$n" address6)"
        selector="$(node_field "$n" interface)"
        wg_peer="$(node_field "$n" wireguard.peer)"
        patch="$OUT/patches/$n.yaml"

        [ -n "$type" ] || die "node $n has no type"
        [ -n "$address" ] || die "node $n has no address"
        # A node without address6 in a cluster with an IPv6 pod CIDR would
        # register v4-only and never serve an IPv6 Service. Catch it here rather
        # than as missing endpoints three days later. Off-LAN nodes are exempt:
        # the WireGuard overlay is v4-only for now and cluster.yaml says so.
        if [ -n "$subnet6" ] && [ -z "$address6" ] && [ -z "$wg_peer" ]; then
            die "cluster.yaml has network.subnet6 but node $n has no address6"
        fi
        if [ -n "$wg_peer" ]; then
            [ -n "$wg_subnet" ] || die "node $n is a WireGuard node but cluster.yaml has no network.wg_subnet"
        fi

        # Tightened before it is written, not after: a WireGuard node's patch
        # carries its private key, and '>' does not reset the mode of a file
        # that already exists from an earlier render.
        : >"$patch"
        chmod 600 "$patch"

        {
            echo "# Generated by talos.sh from cluster.yaml. Do not edit."
            echo "machine:"
            echo "  install:"
            echo "    image: $image"
            echo "  certSANs:"
            echo "    - $vip"
            for m in $(node_names); do
                echo "    - $(node_field "$m" address)"
                [ -n "$(node_field "$m" address6)" ] && echo "    - $(node_field "$m" address6)"
            done
            echo "  kubelet:"
            echo "    nodeIP:"
            # One subnet per family. The kubelet picks its InternalIP from these,
            # and a dual-stack node needs both listed or it registers v4-only and
            # every IPv6 Service quietly has no endpoints.
            echo "      validSubnets:"
            if [ -n "$wg_peer" ]; then
                # Not the LAN subnet: this node's cluster identity is its
                # tunnel address. Pointing the kubelet at the cloud NIC would
                # register a public address nothing else can route back to.
                echo "        - $wg_subnet"
            else
                echo "        - $subnet"
                [ -n "$subnet6" ] && echo "        - $subnet6"
            fi
            echo "  network:"
            echo "    hostname: $n"
            echo "    interfaces:"
            if [ -n "$wg_peer" ]; then
                # The cloud NIC carries the tunnel and, where the provider
                # offers it, public ingress. Its addresses are whatever DHCP
                # hands out — nothing in the cluster depends on them, which is
                # the point: the node's identity is its tunnel address.
                echo "      - deviceSelector:"
                echo "          physical: true"
                echo "        dhcp: true"
                # Stateful DHCPv6 has to be asked for. Infomaniak's ext-net1 is
                # dhcpv6-stateful, so SLAAC alone yields a link-local address
                # and nothing routable.
                if [ "$(node_field "$n" dhcp6)" = "true" ]; then
                    echo "        dhcpOptions:"
                    echo "          ipv4: true"
                    echo "          ipv6: true"
                fi
                emit_wireguard "$n" "$wg_peer" "$address" "$wg_subnet" "$subnet" "$wg_mtu"
            else
                if [ -n "$selector" ]; then
                    echo "      - interface: $selector"
                else
                    # No named interface in cluster.yaml, so match the single
                    # physical NIC. A host with more than one needs 'interface:'
                    # set for it, or Talos configures the same address on both.
                    echo "      - deviceSelector:"
                    echo "          physical: true"
                fi
                echo "        dhcp: false"
                echo "        addresses:"
                echo "          - $address/$prefix"
                [ -n "$address6" ] && echo "          - $address6/$prefix6"
                echo "        routes:"
                echo "          - network: 0.0.0.0/0"
                echo "            gateway: $gateway"
                # Only emitted once cluster.yaml has a gateway6. A default route
                # to a gateway that does not answer costs every outbound v6
                # connection a timeout before it falls back.
                if [ -n "$gateway6" ]; then
                    echo "          - network: ::/0"
                    echo "            gateway: $gateway6"
                fi
                # The VIP is an on-LAN concept: Talos hands it to whichever
                # control-plane node holds etcd leadership, over the LAN link.
                if [ "$type" = "controlplane" ]; then
                    echo "        vip:"
                    echo "          ip: $vip"
                fi
            fi
            # Cluster CIDRs go on every node type: a worker's kube-proxy
            # replacement and CNI both need to know the service range.
            echo "cluster:"
            echo "  network:"
            echo "    podSubnets:"
            cfg '.pod_subnets[]' | while read -r c; do echo "      - $c"; done
            echo "    serviceSubnets:"
            cfg '.service_subnets[]' | while read -r c; do echo "      - $c"; done
            if [ "$type" = "controlplane" ]; then
                echo "  apiServer:"
                echo "    certSANs:"
                echo "      - $vip"
                for m in $(node_names); do
                    echo "      - $(node_field "$m" address)"
                    [ -n "$(node_field "$m" address6)" ] && echo "      - $(node_field "$m" address6)"
                done
            fi
        } >"$patch"

        (umask 077 && talosctl machineconfig patch "$OUT/base/$type.yaml" \
            --patch "@$patch" \
            --patch "@$DIR/nodes/$n.yaml" \
            --output "$OUT/$n.yaml")
        info "rendered $OUT/$n.yaml ($type, $address)"
    done

    # Point talosconfig at the nodes themselves, not the VIP. The VIP does not
    # exist until etcd has a leader, and the first thing you do with this file
    # is bootstrap that etcd.
    local tc="$OUT/base/talosconfig"
    local endpoints=()
    for n in $(node_names); do
        if [ "$(node_field "$n" type)" = "controlplane" ]; then
            endpoints+=("$(node_field "$n" address)")
        fi
    done
    talosctl --talosconfig "$tc" config endpoint "${endpoints[@]}"
    info "talosconfig: $tc"
}

# ------------------------------------------------------------------ operations

talosconfig() {
    local tc="$OUT/base/talosconfig"
    [ -f "$tc" ] || die "no talosconfig — run '$0 render' first"
    printf '%s' "$tc"
}

# Lists the disks on a host still sitting in maintenance mode, which is how you
# fill in nodes/<name>.yaml. Maintenance mode has no PKI yet, hence --insecure.
cmd_disks() {
    local ip="${1:-}"
    [ -n "$ip" ] || die "usage: $0 disks <maintenance-mode-ip>"
    # 'talosctl disks' has no --insecure in 1.13; the COSI resource does, and it
    # is the only thing that answers before the node has PKI.
    talosctl --nodes "$ip" --endpoints "$ip" get disks --insecure
}

# First apply goes to whatever address DHCP handed the node in maintenance mode;
# after that the node owns its static address and normal PKI applies.
cmd_apply() {
    local n="${1:-}" ip="${2:-}"
    [ -n "$n" ] || die "usage: $0 apply <node> [maintenance-ip]"
    require_node "$n"
    [ -f "$OUT/$n.yaml" ] || die "no $OUT/$n.yaml — run '$0 render' first"

    if [ -n "$ip" ]; then
        info "applying $n to $ip in maintenance mode"
        talosctl apply-config --insecure \
            --nodes "$ip" --endpoints "$ip" --file "$OUT/$n.yaml"
    else
        ip="$(node_field "$n" address)"
        info "applying $n to $ip"
        talosctl --talosconfig "$(talosconfig)" \
            apply-config --nodes "$ip" --endpoints "$ip" --file "$OUT/$n.yaml"
    fi
}

# Run once, against one control-plane node only. It creates etcd; the other two
# join it. Running it twice, or on a second node, forks the cluster.
cmd_bootstrap() {
    local n="${1:-}"
    if [ -z "$n" ]; then
        n="$(for m in $(node_names); do
            [ "$(node_field "$m" type)" = "controlplane" ] && echo "$m" && break
        done)"
    fi
    require_node "$n"
    local ip
    ip="$(node_field "$n" address)"

    info "bootstrapping etcd on $n ($ip) — only ever do this once"
    talosctl --talosconfig "$(talosconfig)" \
        bootstrap --nodes "$ip" --endpoints "$ip"
}

cmd_kubeconfig() {
    local vip
    vip="$(cfg .network.vip)"
    (umask 077 && talosctl --talosconfig "$(talosconfig)" \
        kubeconfig "$OUT/kubeconfig" \
        --nodes "$vip" --endpoints "$vip" --force)
    info "wrote $OUT/kubeconfig"
    echo "export KUBECONFIG=$OUT/kubeconfig"
}

cmd_health() {
    local vip
    vip="$(cfg .network.vip)"
    talosctl --talosconfig "$(talosconfig)" \
        health --nodes "$vip" --endpoints "$vip"
}

usage() {
    cat >&2 <<'EOF'
usage: ./talos.sh <command>

  Image
    schematic            resolve schematic.yaml to an Image Factory ID
    iso                  download the metal ISO for that schematic
    usb /dev/sdX         write the ISO to a USB key (destructive, asks first)

  Config
    secrets [--force]    generate the cluster PKI, encrypted with SOPS
    render [node...]     render machine configs into out/ (default: all nodes)

  Bring-up
    disks <ip>           list disks on a node in maintenance mode
    apply <node> [ip]    apply a config; pass the maintenance IP the first time
    bootstrap [node]     create etcd on one control-plane node (once, ever)
    kubeconfig           fetch the cluster kubeconfig
    health               check cluster health
EOF
    exit 1
}

case "${1:-}" in
schematic) shift; cmd_schematic; echo ;;
iso) shift; cmd_iso ;;
usb) shift; cmd_usb "$@" ;;
secrets) shift; cmd_secrets "$@" ;;
render) shift; cmd_render "$@" ;;
disks) shift; cmd_disks "$@" ;;
apply) shift; cmd_apply "$@" ;;
bootstrap) shift; cmd_bootstrap "$@" ;;
kubeconfig) shift; cmd_kubeconfig ;;
health) shift; cmd_health ;;
*) usage ;;
esac
