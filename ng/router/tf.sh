#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/terraform.tfstate"
ENCRYPTED="$DIR/terraform-state.gpg"
PGP_KEY="459895EB0A5F446D3831E99F95F6A162E4A71B06"

cleanup() {
    if [ -f "$STATE" ] && [ -s "$STATE" ]; then
        gpg --encrypt --yes --trust-model always --recipient "$PGP_KEY" \
            --output "$ENCRYPTED" "$STATE" 2>/dev/null || true
    elif [ -f "$ENCRYPTED" ]; then
        rm -f "$ENCRYPTED"
    fi
    rm -f "$STATE" "$STATE.backup"
}
trap cleanup EXIT

case "${1:-}" in
    plan|apply|destroy|refresh|import|taint|untaint|state|output|show)
        if [ -f "$ENCRYPTED" ]; then
            gpg --decrypt --output "$STATE" "$ENCRYPTED"
        fi
        ;;
esac

cd "$DIR"
terraform "$@"
