#!/bin/bash
set -euo pipefail

# Default StorageClass (OpenEBS hostpath). Required: k0s ships none, and the
# k0smotron hosted control plane requests an etcd PVC.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd helm kubectl

OPENEBS_VERSION="${OPENEBS_VERSION:-4.5.1}"
OPENEBS_REPO="${OPENEBS_REPO:-https://openebs.github.io/openebs}"

export KUBECONFIG="$KUBECONFIG_MGMT"

step "Installing OpenEBS $OPENEBS_VERSION (default StorageClass)"

if helm status openebs -n openebs >/dev/null 2>&1; then
    log "OpenEBS is already installed"
else
    helm repo add openebs "$OPENEBS_REPO" --force-update >/dev/null
    helm repo update openebs >/dev/null
    helm install openebs openebs/openebs \
        --version "$OPENEBS_VERSION" \
        -n openebs --create-namespace \
        -f "$CONFIG_DIR/openebs-values.yaml" \
        --timeout 10m
fi

NAMESPACE=openebs "$SCRIPTS_DIR/wait_for_deployment.sh"

step "Verifying the default StorageClass"
default_sc="$(kubectl get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
[[ -n "$default_sc" ]] || die "No default StorageClass after installing OpenEBS"

ok "Default StorageClass: $default_sc"
