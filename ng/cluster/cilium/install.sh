#!/usr/bin/env bash
#
# Installs or upgrades Cilium on the ng cluster.
#
# DEPRECATED: Cilium is now managed by Flux via
# ng/flux/infrastructure/cilium/helmrelease.yaml. This script is kept for
# manual recovery if Flux is unavailable. The values.yaml is still the source
# of truth for Cilium config — keep both files in sync when changing values.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
CHART_VERSION="1.19.6"

: "${KUBECONFIG:=$DIR/../../talos/out/kubeconfig}"
export KUBECONFIG

[ -f "$KUBECONFIG" ] || {
    echo "ERROR: no kubeconfig at $KUBECONFIG — run 'ng/talos/talos.sh kubeconfig'" >&2
    exit 1
}

# Chart name is bare 'cilium', not 'cilium/cilium': with --repo the prefix would
# be read as part of the chart name and the lookup fails.
helm upgrade --install cilium cilium \
    --repo https://helm.cilium.io \
    --version "$CHART_VERSION" \
    --namespace kube-system \
    --values "$DIR/values.yaml" \
    --wait --timeout 10m

echo
echo "Nodes should go Ready within a minute:"
echo "  kubectl get nodes -w"
