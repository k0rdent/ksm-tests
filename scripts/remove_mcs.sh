#!/bin/bash
set -euo pipefail

# Delete the MultiClusterService and verify the service is really gone from the
# child cluster, not just from the management cluster's objects.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

MCS_NAME="$SERVICE_NAME-$CLUSTER_NAME_SUFFIX"
SERVICE_TEMPLATE_NAME="$(service_template_name)"

if ! resource_exists MultiClusterService "$MCS_NAME"; then
    log "MultiClusterService '$MCS_NAME' does not exist -- nothing to remove"
else
    step "Deleting MultiClusterService '$MCS_NAME'"
    kube delete multiclusterservice "$MCS_NAME" --wait=false
    wait_for_absence MultiClusterService "$MCS_NAME" "" "$MCS_TIMEOUT" 5
fi

step "Checking the ServiceSet is gone"
# Only the MCS-owned one: the ClusterDeployment keeps a ServiceSet of its own
# for as long as the cluster exists.
elapsed=0
while (( elapsed < MCS_TIMEOUT )); do
    sset="$(kube get serviceset -n "$NAMESPACE" \
        -o jsonpath="{.items[?(@.spec.multiClusterService==\"$MCS_NAME\")].metadata.name}" 2>/dev/null || true)"
    [[ -z "$sset" ]] && break
    if (( elapsed % 30 == 0 )); then
        log "⏳ ServiceSet '$sset' still present (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done
[[ -z "${sset:-}" ]] || die "ServiceSet '$sset' survived the MultiClusterService"
ok "No ServiceSet left"

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not verifying removal in the child cluster"
else
    step "Checking '$SERVICE_NAME' is gone from the child cluster"
    [[ -f "$KUBECONFIG_CHILD" ]] \
        || die "No child kubeconfig at $KUBECONFIG_CHILD"

    elapsed=0
    while (( elapsed < MCS_TIMEOUT )); do
        # The namespace itself may linger; what matters is that no workload does.
        remaining="$(kube_child get deployments,daemonsets,statefulsets \
            -n "$SERVICE_NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$remaining" == "0" ]] && break
        if (( elapsed % 30 == 0 )); then
            log "⏳ $remaining workload(s) still in '$SERVICE_NAMESPACE' (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    if [[ "${remaining:-0}" != "0" ]]; then
        warn "Workloads still present in '$SERVICE_NAMESPACE' after removal:"
        kube_child get all -n "$SERVICE_NAMESPACE" >&2 || true
        exit 1
    fi
    ok "Child cluster namespace '$SERVICE_NAMESPACE' has no workloads left"
fi

step "Removing the ServiceTemplate"
kube delete servicetemplate "$SERVICE_TEMPLATE_NAME" -n "$NAMESPACE" --ignore-not-found
kube delete helmrepository "$SERVICE_NAME" -n "$NAMESPACE" --ignore-not-found

ok "Service '$SERVICE_NAME' lifecycle completed"
