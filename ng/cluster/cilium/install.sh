#!/usr/bin/env bash
#
# Installs or upgrades Cilium on the ng cluster.
#
# This runs by hand rather than through Flux on purpose: Flux needs a working
# pod network to run at all, so the CNI cannot be the thing Flux installs first.
# Once Cilium is up and Flux is bootstrapped, this same values.yaml can move to
# a HelmRelease and this script retires.

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
