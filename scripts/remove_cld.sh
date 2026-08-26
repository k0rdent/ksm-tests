#!/bin/bash
set -euo pipefail

# Delete the ClusterDeployment under test and verify it is cleaned up.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl
"$SCRIPTS_DIR/check_test_mode.sh"

export KUBECONFIG="$KUBECONFIG_MGMT"

if ! resource_exists ClusterDeployment "$CLD_NAME" "$NAMESPACE"; then
    log "ClusterDeployment '$CLD_NAME' does not exist -- nothing to remove"
    exit 0
fi

step "Deleting ClusterDeployment '$CLD_NAME'"
# --wait=false so the polling and the diagnostics live in one place.
kube delete clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --wait=false

"$SCRIPTS_DIR/wait_for_cluster_removal.sh"

step "Removing the CAPD stub credential"
kube delete credential docker-stub-credential -n "$NAMESPACE" --ignore-not-found
kube delete secret docker-cluster-secret -n "$NAMESPACE" --ignore-not-found
kube delete configmap docker-cluster-credential-resource-template -n "$NAMESPACE" --ignore-not-found

rm -f "$KUBECONFIG_CHILD"

ok "ClusterDeployment lifecycle completed"
