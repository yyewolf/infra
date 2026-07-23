#!/usr/bin/env bash
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/gen-identity.sh" edge-0 "10.10.0.2/32" 51820 "1.2.3.4:51820"
"$DIR/gen-identity.sh" home-router-0 "10.10.0.1/32"
