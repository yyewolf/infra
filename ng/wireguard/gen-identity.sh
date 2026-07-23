#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

SOPS_FILE="ng/wireguard/identities-sops.yaml"

if [ $# -lt 1 ]; then
    echo "usage: $0 <identity-name> [address/cidr] [port] [endpoint]"
    exit 1
fi

NAME="$1"
ADDRESS="${2:-}"
PORT="${3:-51820}"
ENDPOINT="${4:-}"

gen_keypair() {
    if command -v wg >/dev/null 2>&1; then
        local priv=$(wg genkey)
        local pub=$(echo "$priv" | wg pubkey)
        echo "$priv $pub"
    elif python3 -c 'from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey' 2>/dev/null; then
        python3 -c "
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
priv = X25519PrivateKey.generate()
priv_b64 = base64.b64encode(priv.private_bytes_raw()).decode()
pub_b64 = base64.b64encode(priv.public_key().public_bytes_raw()).decode()
print(priv_b64, pub_b64)
"
    else
        echo "ERROR: need 'wg' or 'python3-cryptography'" >&2
        exit 1
    fi
}

read -r PRIV_KEY PUB_KEY <<< "$(gen_keypair)"

echo "Generated identity: $NAME"
echo "  private_key: $PRIV_KEY"
echo "  public_key:  $PUB_KEY"

if [ ! -f "$SOPS_FILE" ]; then
    echo "ERROR: $SOPS_FILE not found" >&2
    exit 1
fi

TMPFILE=$(mktemp -d)/identities-sops.yaml
trap 'rm -f "$TMPFILE"' EXIT

sops -d --output "$TMPFILE" "$SOPS_FILE"

python3 << PYEOF
import sys

name = '$NAME'
priv = '$PRIV_KEY'
pub = '$PUB_KEY'
address = '$ADDRESS'
port = '$PORT'
endpoint = '$ENDPOINT'

with open('$TMPFILE') as f:
    lines = f.readlines()

out = []
# State: which subsection of which identity we're in
# (section, identity) where section is 'secrets' or 'identities'
section = None
identity = None

for line in lines:
    s = line.strip()
    indent = len(line) - len(line.lstrip())

    if indent == 0:
        # Top-level section
        section = None
        identity = None
        if s == 'secrets:':
            section = 'secrets'
        elif s == 'identities:':
            section = 'identities'

    elif section and indent == 4:
        # Identity name within a section
        identity = None
        if s.startswith(name + ':'):
            identity = name

    elif identity and indent == 8:
        # Fields within an identity
        if section == 'secrets' and 'private_key:' in s:
            # Replace value with quoted private key
            colon = line.index(':')
            line = line[:colon+1] + ' "' + priv + '"\n'
        elif section == 'identities':
            if 'public_key:' in s:
                colon = line.index(':')
                line = line[:colon+1] + ' "' + pub + '"\n'
            elif 'address:' in s and address:
                colon = line.index(':')
                line = line[:colon+1] + ' "' + address + '"\n'
            elif 'listen_port:' in s:
                colon = line.index(':')
                line = line[:colon+1] + ' ' + port + '\n'
            elif 'endpoint:' in s:
                colon = line.index(':')
                line = line[:colon+1] + ' "' + endpoint + '"\n'

    out.append(line)

with open('$TMPFILE', 'w') as f:
    f.writelines(out)
PYEOF

sops -e --output "$SOPS_FILE" "$TMPFILE"
echo "Updated $SOPS_FILE"
