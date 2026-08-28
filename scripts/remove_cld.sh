#!/bin/bash
set -euo pipefail

# Delete the ClusterDeployment and the credential that adopted the cluster.
# The cluster container itself is cleanup.sh's job -- KCM never owned it.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl
"$SCRIPTS_DIR/check_test_mode.sh"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

ADOPTED_SECRET_NAME="${ADOPTED_SECRET_NAME:-adopted-kubeconf-$CLUSTER_NAME_SUFFIX}"
ADOPTED_CREDENTIAL_NAME="${ADOPTED_CREDENTIAL_NAME:-adopted-cred-$CLUSTER_NAME_SUFFIX}"

if resource_exists ClusterDeployment "$CLD_NAME" "$NAMESPACE"; then
    step "Deleting ClusterDeployment '$CLD_NAME'"
    kube delete clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --wait=false
    wait_for_absence ClusterDeployment "$CLD_NAME" "$NAMESPACE" "$CLD_REMOVAL_TIMEOUT" 5

    # The chart is gone only once its SveltosCluster is, and a lingering one
    # would let a later run deploy into a cluster nobody is watching.
    step "Checking the SveltosCluster is gone"
    elapsed=0
    while (( elapsed < CLD_REMOVAL_TIMEOUT )); do
        left="$(kube get sveltoscluster -n "$NAMESPACE" \
            -o jsonpath="{.items[?(@.metadata.name==\"$CLD_NAME\")].metadata.name}" 2>/dev/null || true)"
        [[ -z "$left" ]] && break
        (( elapsed % 30 == 0 )) && log "⏳ SveltosCluster '$left' still present (${elapsed}s)"
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    [[ -z "${left:-}" ]] || { kube get sveltoscluster -A >&2 || true
                              die "SveltosCluster '$left' survived the ClusterDeployment"; }
else
    log "ClusterDeployment '$CLD_NAME' does not exist -- nothing to remove"
fi

step "Removing the adopted credential"
kube delete credential "$ADOPTED_CREDENTIAL_NAME" -n "$NAMESPACE" --ignore-not-found
kube delete secret "$ADOPTED_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found

ok "ClusterDeployment lifecycle completed"
