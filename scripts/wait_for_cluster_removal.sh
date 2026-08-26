#!/bin/bash
set -euo pipefail

# Wait for the ClusterDeployment to disappear and confirm CAPD left no
# orphaned containers behind.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl docker

export KUBECONFIG="$KUBECONFIG_MGMT"

step "Waiting for ClusterDeployment '$CLD_NAME' to be removed"
if ! wait_for_absence ClusterDeployment "$CLD_NAME" "$NAMESPACE" "$CLD_REMOVAL_TIMEOUT" 10; then
    warn "Objects still holding the deletion up:"
    {
        kube get clusters,machines -n "$NAMESPACE" -o wide
        kube get devclusters,devmachines -n "$NAMESPACE" -o wide
    } >&2 2>/dev/null || true
    exit 1
fi

step "Checking the CAPI objects are gone"
for kind in cluster machine devcluster devmachine; do
    leftovers="$(kube get "$kind" -n "$NAMESPACE" -o name 2>/dev/null | grep -- "$CLD_NAME" || true)"
    if [[ -n "$leftovers" ]]; then
        die "Leftover $kind objects after deletion: $(echo "$leftovers" | tr '\n' ' ')"
    fi
done
ok "No leftover CAPI objects"

step "Checking CAPD left no containers behind"
# CAPD names the node containers <cluster>-<role>-<suffix>.
orphans="$(docker ps -a --filter "name=^$CLD_NAME-" --format '{{.Names}}')"
if [[ -n "$orphans" ]]; then
    die "Orphaned CAPD containers: $(echo "$orphans" | tr '\n' ' ')"
fi

ok "ClusterDeployment '$CLD_NAME' fully removed"
