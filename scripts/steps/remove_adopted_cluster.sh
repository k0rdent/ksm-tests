#!/usr/bin/env bash
# Remove the adopted ClusterDeployment and the cluster behind it. Best-effort,
# like remove_k0rdent.sh: this runs from CI's always() and from a trap, so a
# half-built environment must not make it fail.
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

if [[ "$TEST_MODE" != "adopted" ]]; then
    log "TEST_MODE=$TEST_MODE -- nothing adopted to remove"
    exit 0
fi

step "Removing the adopted cluster '$ADOPTED_CLUSTER_NAME'"

# The ClusterDeployment first and on its own: deleting the Credential out from
# under it leaves KCM unable to reach the cluster it is trying to detach from.
if [[ -f "$KUBECONFIG_MGMT" ]]; then
    export KUBECONFIG="$KUBECONFIG_MGMT"

    if resource_exists ClusterDeployment "$ADOPTED_CLD_NAME" "$NAMESPACE"; then
        kube delete clusterdeployment "$ADOPTED_CLD_NAME" -n "$NAMESPACE" --wait=false
        wait_for_absence ClusterDeployment "$ADOPTED_CLD_NAME" "$NAMESPACE" "$REMOVE_TIMEOUT" 5 \
            || warn "ClusterDeployment '$ADOPTED_CLD_NAME' is still there -- removing the cluster anyway"
    else
        log "No ClusterDeployment '$ADOPTED_CLD_NAME'"
    fi

    kube delete credential "$ADOPTED_CRED_NAME" -n "$NAMESPACE" --ignore-not-found
    kube delete secret "$ADOPTED_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found
else
    log "No management kubeconfig -- removing the container only"
fi

if command -v docker >/dev/null 2>&1 \
   && docker ps -a --format '{{.Names}}' | grep -qx "$ADOPTED_CLUSTER_NAME"; then
    log "Removing container '$ADOPTED_CLUSTER_NAME'"
    docker rm -vf "$ADOPTED_CLUSTER_NAME" >/dev/null 2>&1
fi

rm -f "$KUBECONFIG_ADOPTED" "$KUBECONFIG_ADOPTED.bak" \
      "$ENVDIR/adopted-kubeconfig.incluster.yaml" \
      "$ENVDIR/adopted-credential.rendered.yaml" \
      "$ENVDIR/adopted-clusterdeployment.rendered.yaml"

ok "Adopted cluster removed"
