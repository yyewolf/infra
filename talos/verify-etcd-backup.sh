#!/usr/bin/env bash
# Rehearse an etcd restore without touching the cluster.
#
# Pulls a snapshot from Swiss Backup, decrypts it with the age key, decompresses
# it and asks etcdutl whether it is a valid, restorable etcd database. Nothing
# here talks to the running cluster; the only network access is the S3 GET.
#
#   ./verify-etcd-backup.sh                 # newest snapshot
#   ./verify-etcd-backup.sh --list          # list what is in the bucket
#   ./verify-etcd-backup.sh <key>           # a specific one, e.g. etcd/ng-....age
#   ./verify-etcd-backup.sh --keep          # leave the restored data dir in place
#
# WHAT THIS PROVES
#   - the object downloads and the age key decrypts it (so the key in
#     etcd-backup-age-sops-all.yaml really is the one talos-backup encrypts to)
#   - the plaintext is an intact etcd database: etcdutl verifies the integrity
#     hash etcd appends to every snapshot, so silent corruption in transit or at
#     rest is caught here
#   - `etcdutl snapshot restore` can rebuild a data directory from it, which is
#     the actual first step of a real recovery
#
# A NOTE ON WHAT IT LEAVES ON DISK
#   The decrypted snapshot is every Secret in the cluster in the clear. It is
#   written under a 0700 temp directory and shredded on exit unless --keep is
#   passed. Run it somewhere you would be comfortable holding the cluster's
#   secrets, and do not pass --keep on a shared machine.
set -euo pipefail

cd "$(dirname "$0")"

AGE_SOPS="etcd-backup-age-sops-all.yaml"
S3_SOPS="../flux/platform/talos-backup/s3-credentials-sops.yaml"
BUCKET="default"
PREFIX="etcd"
ENDPOINT="https://s3.swiss-backup02.infomaniak.com"
REGION="us-east-1"
RCLONE_IMAGE="rclone/rclone:1.74.4"
# Match the cluster's own etcd (talosctl image list). A newer etcdutl will read
# an older snapshot, but keeping these equal removes the question.
ETCD_IMAGE="registry.k8s.io/etcd:v3.6.12"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for b in sops age zstd docker; do command -v "$b" >/dev/null || die "missing: $b"; done
[ -f "$AGE_SOPS" ] || die "no $AGE_SOPS — run this from talos/"
[ -f "$S3_SOPS" ]  || die "no $S3_SOPS"

KEEP=0; LIST=0; WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) WANT="$1" ;;
  esac
  shift
done

umask 077
WORK=$(mktemp -d)
cleanup() {
  if [ "$KEEP" = 1 ]; then
    info "left in place: $WORK"
  else
    find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- credentials -------------------------------------------------------------
# Read straight into variables. Never echoed, never written to disk except the
# age identity, which needs to be a file for age -i and is shredded on exit.
info "decrypting credentials (sops will prompt for your GPG key)"
# `sops decrypt --extract`, not `sops -d --extract`: the subcommand form is the
# one that carries the flag in sops 3.9+.
AK=$(sops decrypt --extract '["stringData"]["AWS_ACCESS_KEY_ID"]' "$S3_SOPS")
SK=$(sops decrypt --extract '["stringData"]["AWS_SECRET_ACCESS_KEY"]' "$S3_SOPS")
sops decrypt --extract '["privateKey"]' "$AGE_SOPS" > "$WORK/age.key"
[ -s "$WORK/age.key" ] || die "age private key came back empty"

rclone() {
  docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    -e RCLONE_CONFIG_SB_TYPE=s3 \
    -e RCLONE_CONFIG_SB_PROVIDER=Other \
    -e RCLONE_CONFIG_SB_ENDPOINT="$ENDPOINT" \
    -e RCLONE_CONFIG_SB_REGION="$REGION" \
    -e RCLONE_CONFIG_SB_FORCE_PATH_STYLE=true \
    -e RCLONE_CONFIG_SB_ACCESS_KEY_ID="$AK" \
    -e RCLONE_CONFIG_SB_SECRET_ACCESS_KEY="$SK" \
    -e RCLONE_CONFIG=/tmp/rclone.conf \
    -v "$WORK:/data" \
    "$RCLONE_IMAGE" "$@"
}

if [ "$LIST" = 1 ]; then
  info "snapshots in s3://$BUCKET/$PREFIX"
  rclone lsl "sb:$BUCKET/$PREFIX"
  exit 0
fi

# --- pick and fetch ----------------------------------------------------------
if [ -z "$WANT" ]; then
  # Names are RFC3339 timestamps, so lexical sort is chronological.
  WANT=$(rclone lsf "sb:$BUCKET/$PREFIX" | sort | tail -1 | tr -d '\r')
  [ -n "$WANT" ] || die "no snapshots found under $PREFIX/"
  WANT="$PREFIX/$WANT"
fi
info "snapshot: $WANT"

BASE=$(basename "$WANT")
rclone copyto "sb:$BUCKET/$WANT" "/data/$BASE"
[ -s "$WORK/$BASE" ] || die "download produced nothing"
info "downloaded $(du -h "$WORK/$BASE" | cut -f1)"

# --- decrypt, decompress -----------------------------------------------------
head -c 21 "$WORK/$BASE" | grep -q '^age-encryption.org/v1' \
  || die "not an age file — is this really a talos-backup object?"

info "decrypting with the age key"
age -d -i "$WORK/age.key" -o "$WORK/snap.zst" "$WORK/$BASE" \
  || die "age failed — the private key does not match the recipient used for this snapshot"

info "decompressing"
zstd -q -d -f "$WORK/snap.zst" -o "$WORK/snap.db"
info "snapshot is $(du -h "$WORK/snap.db" | cut -f1) uncompressed"

etcdutl() {
  docker run --rm -i --user "$(id -u):$(id -g)" \
    -v "$WORK:/data" --entrypoint /usr/local/bin/etcdutl "$ETCD_IMAGE" "$@"
}

# --- validate ----------------------------------------------------------------
# This is the integrity check: etcd appends a hash to every snapshot and etcdutl
# recomputes it. A mismatch here means the file is corrupt, not that it is old.
info "etcdutl snapshot status"
etcdutl snapshot status /data/snap.db -w table

# The dress rehearsal. Rebuilding a data directory is what a real recovery does
# first; if this succeeds the snapshot is genuinely restorable and not merely
# well-formed.
info "etcdutl snapshot restore (into a throwaway dir, cluster untouched)"
etcdutl snapshot restore /data/snap.db --data-dir /data/restored >/dev/null
[ -d "$WORK/restored/member/snap" ] || die "restore produced no member data"

info "restored data dir: $(du -sh "$WORK/restored" | cut -f1)"
printf '\n\033[1;32mOK\033[0m — %s decrypts, verifies and restores.\n' "$BASE"
echo "Real recovery would be: talosctl bootstrap --recover-from=<snapshot.db>"
