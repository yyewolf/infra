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

    local name vip gateway subnet version k8s image
    name="$(cfg .name)"
    vip="$(cfg .network.vip)"
    gateway="$(cfg .network.gateway)"
    subnet="$(cfg .network.subnet)"
    version="$(cfg .talos_version)"
    k8s="$(cfg .kubernetes_version)"

    local prefix="${subnet##*/}"

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
    trap 'rm -f "$plain"' RETURN
    (umask 077 && sops -d --output "$plain" "$SECRETS")

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
        local type address selector patch
        type="$(node_field "$n" type)"
        address="$(node_field "$n" address)"
        selector="$(node_field "$n" interface)"
        patch="$OUT/patches/$n.yaml"

        [ -n "$type" ] || die "node $n has no type"
        [ -n "$address" ] || die "node $n has no address"

        {
            echo "# Generated by talos.sh from cluster.yaml. Do not edit."
            echo "machine:"
            echo "  install:"
            echo "    image: $image"
            echo "  certSANs:"
            echo "    - $vip"
            for m in $(node_names); do echo "    - $(node_field "$m" address)"; done
            echo "  kubelet:"
            echo "    nodeIP:"
            echo "      validSubnets:"
            echo "        - $subnet"
            echo "  network:"
            echo "    hostname: $n"
            echo "    interfaces:"
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
            echo "        routes:"
            echo "          - network: 0.0.0.0/0"
            echo "            gateway: $gateway"
            if [ "$type" = "controlplane" ]; then
                echo "        vip:"
                echo "          ip: $vip"
            fi
            if [ "$type" = "controlplane" ]; then
                echo "cluster:"
                echo "  apiServer:"
                echo "    certSANs:"
                echo "      - $vip"
                for m in $(node_names); do echo "      - $(node_field "$m" address)"; done
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
