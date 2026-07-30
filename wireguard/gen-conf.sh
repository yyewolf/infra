#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SOPS_FILE="ng/wireguard/identities-sops.yaml"

PEER="home-router-0"
ENDPOINT=""
ALLOWED_IPS="10.200.255.0/24,10.200.0.0/24"
DNS=""
KEEPALIVE="25"
OUTPUT=""

usage() {
    cat >&2 <<'EOF'
usage: gen-conf.sh <identity> [options]

Renders a WireGuard client config for <identity> from the identity registry.
Prints to stdout unless -o is given.

options:
  -p, --peer <name>         peer to connect to (default: home-router-0)
  -e, --endpoint <host:port>
                            override the peer's endpoint, required when the
                            registry leaves it empty
  -a, --allowed-ips <list>  comma separated networks to route over the tunnel
                            (default: 10.200.255.0/24,10.200.0.0/24)
  -d, --dns <address>       DNS server for the tunnel (default: none)
  -k, --keepalive <secs>    PersistentKeepalive, 0 to omit (default: 25)
  -o, --output <file>       write with mode 600 instead of printing

The output contains a private key in cleartext. It is never written inside
the repository.
EOF
    exit 1
}

[ $# -ge 1 ] || usage
NAME="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        -p | --peer)        PEER="$2";        shift 2 ;;
        -e | --endpoint)    ENDPOINT="$2";    shift 2 ;;
        -a | --allowed-ips) ALLOWED_IPS="$2"; shift 2 ;;
        -d | --dns)         DNS="$2";         shift 2 ;;
        -k | --keepalive)   KEEPALIVE="$2";   shift 2 ;;
        -o | --output)      OUTPUT="$2";      shift 2 ;;
        -h | --help)        usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

[ -f "$SOPS_FILE" ] || { echo "ERROR: $SOPS_FILE not found" >&2; exit 1; }

if [ -n "$OUTPUT" ]; then
    OUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
    case "$OUT_DIR/" in
        "$REPO_ROOT"/*)
            echo "ERROR: refusing to write a private key inside the repository" >&2
            echo "       pick a path outside $REPO_ROOT" >&2
            exit 1
            ;;
    esac
fi

# Piped rather than decrypted to a temp file so the plaintext never touches disk.
CONF="$(
    sops -d --output-type json "$SOPS_FILE" |
        python3 "$SCRIPT_DIR/gen-conf.py" \
            "$NAME" "$PEER" "$ENDPOINT" "$ALLOWED_IPS" "$DNS" "$KEEPALIVE"
)"

if [ -n "$OUTPUT" ]; then
    (umask 077 && printf '%s\n' "$CONF" > "$OUTPUT")
    echo "Wrote $OUTPUT (mode 600)" >&2
else
    printf '%s\n' "$CONF"
fi
