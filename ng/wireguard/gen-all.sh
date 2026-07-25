#!/usr/bin/env bash
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/gen-identity.sh" admin-0 "10.200.255.3/32" 51820 "192.168.1.52:51820"
"$DIR/gen-identity.sh" edge-0 "10.200.255.2/32" 51820 "1.2.3.4:51820"
"$DIR/gen-identity.sh" home-router-0 "10.200.255.1/32"
