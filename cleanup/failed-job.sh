#!/usr/bin/env bash
# cleanup_failed_jobs.sh
# Cleans up failed Kubernetes Jobs across namespaces

set -euo pipefail

# Optional: specify a namespace as the first argument
NAMESPACE="${1:-}"

if [[ -n "$NAMESPACE" ]]; then
  echo "🔍 Cleaning up failed Jobs in namespace: $NAMESPACE"
  JOBS=$(kubectl get jobs -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$3 > 0 {print $1}')
else
  echo "🔍 Cleaning up failed Jobs in all namespaces"
  JOBS=$(kubectl get jobs --all-namespaces --no-headers 2>/dev/null | awk '$4 > 0 {print $2 "," $1}')
fi

if [[ -z "$JOBS" ]]; then
  echo "✅ No failed Jobs found."
  exit 0
fi

echo "🧾 Found failed Jobs:"
echo "$JOBS" | tr ',' '\t'

read -p "❓ Proceed to delete these Jobs? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "🚫 Aborted."
  exit 0
fi

echo "🧨 Deleting failed Jobs..."

if [[ -n "$NAMESPACE" ]]; then
  for JOB in $JOBS; do
    kubectl delete job "$JOB" -n "$NAMESPACE"
  done
else
  while IFS=',' read -r JOB NS; do
    kubectl delete job "$JOB" -n "$NS"
  done <<< "$JOBS"
fi

echo "✅ Cleanup complete."
