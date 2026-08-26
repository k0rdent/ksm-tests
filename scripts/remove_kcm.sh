#!/bin/bash
set -euo pipefail

# Uninstall KCM. Management goes first -- it owns the provider HelmReleases,
# and removing the chart before them strands the controller with the finalizers.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl helm

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

if ! kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "Namespace '$NAMESPACE' does not exist -- nothing to uninstall"
    exit 0
fi

if resource_exists Management kcm; then
    step "Deleting the Management object"
    kube delete management kcm --wait=false
    wait_for_absence Management kcm "" "${MANAGEMENT_REMOVAL_TIMEOUT:-900}" 10 \
        || die "Management 'kcm' was not removed"
fi

if helm status "$KCM_HELM_RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    step "Uninstalling the KCM Helm release"
    helm uninstall "$KCM_HELM_RELEASE_NAME" -n "$NAMESPACE" --timeout 10m --wait
else
    log "Helm release '$KCM_HELM_RELEASE_NAME' not found"
fi

step "Checking what is left in '$NAMESPACE'"
# CRDs are annotated helm.sh/resource-policy: keep, so they are expected to
# survive; workloads are not.
remaining="$(kube get deployments -n "$NAMESPACE" -o name 2>/dev/null || true)"
if [[ -n "$remaining" ]]; then
    warn "Deployments still present after uninstall:"
    echo "$remaining" >&2
else
    ok "No deployments left in '$NAMESPACE'"
fi

ok "KCM uninstalled"
