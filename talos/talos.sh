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

# Shared with router, which builds its WireGuard peers from the same file.
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

# Uploads a schematic file and prints the resulting ID. The factory is
# content-addressed, so re-uploading an unchanged file returns the same ID and
# costs nothing but a round trip. Each cache file holds the hash of its input
# and the ID that came back, so render/iso do not both re-upload.
resolve_schematic() {
    need curl
    local file="$1" cache="$2" hash
    hash="$(sha256sum "$file" | cut -d' ' -f1)"

    if [ -f "$cache" ] && [ "$(head -n1 "$cache")" = "$hash" ]; then
        tail -n1 "$cache"
        return
    fi

    info "uploading $(basename "$file") to $FACTORY"
    local id
    id="$(curl -fsSL -X POST --data-binary "@$file" "$FACTORY/schematics" |
        jq -r '.id')"
    [ -n "$id" ] && [ "$id" != "null" ] || die "factory did not return a schematic ID"

    mkdir -p "$(dirname "$cache")"
    printf '%s\n%s\n' "$hash" "$id" >"$cache"
    printf '%s' "$id"
}

# The base schematic: what the ISO is built from, and what any node without
# per-node extensions installs. openstack reads out/schematic-id directly to
# build edge-0's Glance image, so this file's meaning is load-bearing outside
# this script — it is the *base* ID, never a node's merged one.
cmd_schematic() {
    resolve_schematic "$SCHEMATIC" "$OUT/schematic-id"
}

# A node's own schematic ID. Nodes with no 'extensions' in cluster.yaml share
# the base one; the rest get schematic.yaml with their extra extensions merged
# in, written to out/schematics/<node>.yaml and resolved separately. That is the
# whole point of the per-node list: adding an extension to one host must not
# change the installer image of any other.
node_schematic_id() {
    local n="$1"
    local extras=()
    mapfile -t extras < <(cfg ".nodes.\"$n\".extensions[]?")
    [ ${#extras[@]} -eq 0 ] && { cmd_schematic; return; }

    # edge-0 and any future off-LAN node are built by Terraform from
    # out/schematic-id, not from anything this function writes. Giving one
    # extensions here would have it install an image the cloud instance was
    # never booted from — silently, and only visible after a reboot.
    if [ -n "$(node_field "$n" wireguard.peer)" ]; then
        die "node $n has per-node extensions, but off-LAN nodes are imaged by openstack from the base schematic — put them in schematic.yaml instead"
    fi

    local merged="$OUT/schematics/$n.yaml" list=""
    for e in "${extras[@]}"; do list+="\"$e\","; done
    mkdir -p "$OUT/schematics"
    yq ".customization.systemExtensions.officialExtensions =
          ((.customization.systemExtensions.officialExtensions // []) + [${list%,}] | unique)" \
        "$SCHEMATIC" >"$merged"

    resolve_schematic "$merged" "$OUT/schematics/$n.id"
}

# ------------------------------------------------------------ custom installer
#
# Extensions that are not on the Image Factory. The factory only layers
# extensions from its own registered set and rejects an OCI reference at build
# time, so a node wanting one cannot get its installer from the factory at all —
# it has to be built here, with siderolabs/imager, and pushed somewhere the node
# can pull from.
#
# The trap this replaces: '--system-extension-image' does not *add* to the base
# installer, it *replaces* the base's entire extension set with exactly what is
# named on the command line. Passing only the custom extension — even with
# '--base-installer-image' pointing at the node's factory installer — produces
# an image carrying that extension and nothing else. Doing this by hand once
# left a node without iscsi-tools, which took Longhorn down on it. So the list
# below is assembled from the node's *complete* extension set, official ones
# included, and never from the custom entries alone.

node_custom_extensions() { cfg ".nodes.\"$1\".custom_extensions[]?"; }

# Every official extension this node carries, as concrete pinned OCI references.
# The factory publishes the ref and digest it would itself use for a given Talos
# version, so the image imager builds is the image the factory would have built.
official_extension_refs() {
    local n="$1" version wanted
    version="$(cfg .talos_version)"

    wanted="$( {
        yq -r '.customization.systemExtensions.officialExtensions[]?' "$SCHEMATIC"
        cfg ".nodes.\"$n\".extensions[]?"
    } | sort -u)"

    local catalog
    catalog="$(curl -fsSL "$FACTORY/version/$version/extensions/official")" ||
        die "could not fetch the official extension catalog for $version"

    local name ref
    while read -r name; do
        [ -n "$name" ] || continue
        ref="$(printf '%s' "$catalog" |
            jq -r --arg n "$name" '.[] | select(.name == $n) | "\(.ref|sub(":[^:/]*$";""))@\(.digest)"')"
        [ -n "$ref" ] && [ "$ref" != "null" ] ||
            die "extension '$name' is not available for Talos $version"
        printf '%s\n' "$ref"
    done <<<"$wanted"
}

# The complete extension set for a node, official first, then custom. This is
# the whole input to the image, and the order is stable so the hash below is.
installer_refs() {
    official_extension_refs "$1"
    node_custom_extensions "$1"
}

# Identifies an installer by what went into it, which is what the build is
# cached and tagged on. Two nodes asking for the same extension set at the same
# Talos version get the same hash, so the image is built and pushed once and
# both point at it — as all three LAN hosts currently do. It also means a
# changed extension list is a cache miss rather than a silently stale image.
installer_hash() {
    local body
    body="$(installer_refs "$1")" ||
        die "could not resolve the extension list for $1"
    printf '%s\n%s\n' "$(cfg .talos_version)" "$body" | sha256sum | cut -d' ' -f1
}

# Where the pushed reference for a given hash is remembered. Under out/, so it
# is throwaway — but unlike a schematic ID it cannot be re-derived by asking a
# service, only by rebuilding and re-pushing. A fresh clone therefore needs
# 'installer' run once before render, which is what installer_image() says.
installer_cache() { printf '%s/installer/%s.ref' "$OUT" "$1"; }

# Builds and pushes this node's installer, printing the pushed digest. Cached
# like schematic IDs: the cache holds a hash of everything that went into the
# image, so an unchanged node does not rebuild and re-push.
#
# Requires push credentials for installer_repository. Nothing here reads them —
# that is docker's business — but a registry that rejects the push fails the
# command rather than silently leaving the digest stale.
cmd_installer() {
    need docker
    need curl
    need jq
    local n="${1:-}"
    [ -n "$n" ] || die "usage: $0 installer <node>"
    require_node "$n"

    local repo version
    repo="$(cfg '.installer_repository // ""')"
    [ -n "$repo" ] || die "cluster.yaml has no installer_repository"
    version="$(cfg .talos_version)"

    # Via a variable, not 'mapfile < <(installer_refs)': a die() inside process
    # substitution kills only that subshell, and mapfile would happily succeed
    # on the partial list — building an image missing whatever came after the
    # failure. Command substitution propagates, so long as the assignment is not
    # also a declaration.
    local refs_raw refs=()
    refs_raw="$(installer_refs "$n")" ||
        die "could not resolve the extension list for $n"
    mapfile -t refs <<<"$refs_raw"
    [ ${#refs[@]} -gt 0 ] || die "node $n has no extensions to build an installer from"

    local hash cache build
    hash="$(installer_hash "$n")"
    cache="$(installer_cache "$hash")"
    if [ -f "$cache" ]; then
        info "installer for $n already built and pushed"
        cat "$cache"
        return
    fi

    local args=(--arch amd64)
    for r in "${refs[@]}"; do args+=(--system-extension-image "$r"); done

    # Every extension the node has, official ones included — never just the
    # custom ones. See the note at the top of this section for what happens
    # otherwise.
    info "building installer for $n with ${#refs[@]} extensions"
    build="$OUT/installer/$hash"
    rm -rf "$build"
    mkdir -p "$build"
    docker run --rm -t -v "$build:/out" \
        "ghcr.io/siderolabs/imager:$version" installer "${args[@]}" >&2

    # imager tags the loaded image after the base it built from, not after
    # anything we asked for, so read the tag back rather than assuming it.
    local loaded
    loaded="$(docker load -i "$build/installer-amd64.tar" |
        sed -n 's/^Loaded image: //p' | tail -n1)"
    [ -n "$loaded" ] || die "could not determine the image docker just loaded"

    # Tagged by content, not by node: the tag is only a handle for the push and
    # for reading the registry later. What nodes install is the digest below.
    local tag="$repo:$version-${hash:0:12}"
    docker tag "$loaded" "$tag"
    docker rmi "$loaded" >/dev/null 2>&1 || true

    info "pushing $tag"
    local digest
    digest="$(docker push "$tag" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p' | tail -n1)"
    [ -n "$digest" ] || die "push did not report a digest"

    mkdir -p "$(dirname "$cache")"
    printf '%s@%s' "$repo" "$digest" >"$cache"
    rm -rf "$build"
    cat "$cache"
}

# What a node installs. Nodes with custom extensions install the image built
# above; everything else installs straight from the factory.
#
# Deliberately does not build on demand: render and upgrade would then push to a
# registry as a side effect of an otherwise read-only command. Run 'installer'
# first — the error says so.
installer_image() {
    local n="$1"
    if [ -n "$(node_custom_extensions "$n")" ]; then
        local cache
        cache="$(installer_cache "$(installer_hash "$n")")"
        [ -f "$cache" ] ||
            die "node $n has custom_extensions but no installer built for its current extension list — run '$0 installer $n' first"
        cat "$cache"
        return
    fi
    printf 'factory.talos.dev/metal-installer/%s:%s' \
        "$(node_schematic_id "$1")" "$(cfg .talos_version)"
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

    local name vip gateway subnet subnet6 gateway6 wg_subnet wg_mtu version k8s
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
        local type address address6 selector patch wg_peer image
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

        # Per node, not once for the whole run: a node with extra extensions
        # installs a different image from the rest of the cluster.
        image="$(installer_image "$n")"

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

        # Extra patches this node asked for in cluster.yaml. They sit between
        # the generated patch and the hardware facts on purpose: a node patch
        # may reference nothing derived from cluster.yaml, and nodes/<n>.yaml
        # stays the last word on the install disk.
        local extra_patches=()
        for p in $(node_field "$n" 'patches[]?'); do
            [ -f "$DIR/patches/$p" ] ||
                die "node $n lists patch '$p' but $DIR/patches/$p does not exist"
            extra_patches+=(--patch "@$DIR/patches/$p")
        done

        (umask 077 && talosctl machineconfig patch "$OUT/base/$type.yaml" \
            --patch "@$patch" \
            "${extra_patches[@]+"${extra_patches[@]}"}" \
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

# Applying a config is not enough to change the image a node is *running*:
# machine.install.image only decides what the next install writes. A new Talos
# version or a changed extension list needs this, which reboots the node onto
# the new image. One node at a time — with three control-plane nodes, etcd
# tolerates exactly one being away.
# The drain is run here rather than by talosctl, because on this cluster it
# routinely cannot finish and the caller has to decide what to do about it.
#
# Why it blocks: the longhorn-yolo and longhorn-ci storage classes are
# numberOfReplicas 1, so a node holding one of those volumes always holds its
# *last* replica, and Longhorn's default node-drain-policy of
# block-if-contains-last-replica keeps a PodDisruptionBudget on that node's
# instance-manager with zero allowed disruptions. This is the replica count,
# not the data locality — moving longhorn-yolo to best-effort does not lift it. The eviction is refused for as
# long as the policy stands, which is forever — this is not a slow drain waiting
# to succeed. 'talosctl upgrade' handles that by timing out and aborting with
# the node left cordoned and its stateful pods already evicted, which is the
# worst of both outcomes.
#
# So: drain with a short timeout, and if it blocks, say what blocked it and ask.
# Continuing is usually right — the workloads are off the node by then, and what
# remains is Longhorn's own node agents, which come back on reboot. The data is
# on the node's disk and survives, single replica or not.
cmd_upgrade() {
    local n="${1:-}"
    [ -n "$n" ] || die "usage: $0 upgrade <node> [talosctl upgrade flags...]"
    require_node "$n"
    shift

    local ip image
    ip="$(node_field "$n" address)"
    image="$(installer_image "$n")"

    local kubeconfig="$OUT/kubeconfig"
    if [ ! -f "$kubeconfig" ] || ! command -v kubectl >/dev/null 2>&1; then
        info "no kubectl or no $kubeconfig — skipping the drain, talosctl will do its own"
        info "upgrading $n ($ip) to $image"
        talosctl --talosconfig "$(talosconfig)" \
            upgrade --nodes "$ip" --endpoints "$ip" --image "$image" "$@"
        return
    fi

    info "draining $n"
    if kubectl --kubeconfig "$kubeconfig" drain "$n" \
        --ignore-daemonsets --delete-emptydir-data --timeout=120s; then
        info "drained cleanly"
    else
        echo >&2
        info "the drain did not finish. Still on $n:"
        kubectl --kubeconfig "$kubeconfig" get pods --all-namespaces \
            --field-selector "spec.nodeName=$n" \
            -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase' >&2 || true
        echo >&2
        info "DaemonSet and Longhorn node agents are expected here and return on reboot."
        info "Anything stateful in that list will be interrupted."
        echo >&2

        local reply
        [ -e /dev/tty ] ||
            die "the drain of $n did not finish and there is no terminal to ask on"
        read -r -p "Reboot $n anyway? [y/N] " reply </dev/tty
        case "$reply" in
        y | Y | yes | YES) ;;
        *)
            info "uncordoning $n and stopping"
            kubectl --kubeconfig "$kubeconfig" uncordon "$n" || true
            die "upgrade of $n cancelled"
            ;;
        esac
    fi

    # --drain=false either way: the node is already cordoned and drained as far
    # as it is going to get, and letting talosctl try again just repeats the
    # eviction that was already refused.
    info "upgrading $n ($ip) to $image"
    talosctl --talosconfig "$(talosconfig)" \
        upgrade --nodes "$ip" --endpoints "$ip" --image "$image" --drain=false "$@"

    info "uncordoning $n"
    kubectl --kubeconfig "$kubeconfig" uncordon "$n" || true
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
                         (the base image; per-node extensions are resolved
                          separately by render)
    installer <node>     build and push this node's installer image, for nodes
                         carrying extensions the Image Factory does not have
                         (run before render/upgrade when that list changes)
    iso                  download the metal ISO for that schematic
    usb /dev/sdX         write the ISO to a USB key (destructive, asks first)

  Config
    secrets [--force]    generate the cluster PKI, encrypted with SOPS
    render [node...]     render machine configs into out/ (default: all nodes)

  Bring-up
    disks <ip>           list disks on a node in maintenance mode
    apply <node> [ip]    apply a config; pass the maintenance IP the first time
    upgrade <node> [..]  drain, then reboot a node onto its installer image;
                         asks before continuing if the drain blocks.
                         Extra flags are passed to talosctl upgrade
    bootstrap [node]     create etcd on one control-plane node (once, ever)
    kubeconfig           fetch the cluster kubeconfig
    health               check cluster health
EOF
    exit 1
}

case "${1:-}" in
schematic) shift; cmd_schematic; echo ;;
installer) shift; cmd_installer "$@"; echo ;;
iso) shift; cmd_iso ;;
usb) shift; cmd_usb "$@" ;;
secrets) shift; cmd_secrets "$@" ;;
render) shift; cmd_render "$@" ;;
disks) shift; cmd_disks "$@" ;;
apply) shift; cmd_apply "$@" ;;
upgrade) shift; cmd_upgrade "$@" ;;
bootstrap) shift; cmd_bootstrap "$@" ;;
kubeconfig) shift; cmd_kubeconfig ;;
health) shift; cmd_health ;;
*) usage ;;
esac
