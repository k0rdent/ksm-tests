#!/bin/bash
set -euo pipefail

# Deploy the service to the child cluster through a MultiClusterService, then
# verify it actually landed there -- an MCS reporting success is not proof the
# workload is running.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst jq

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

SERVICE_TEMPLATE_NAME="$(service_template_name)"
MCS_NAME="$SERVICE_NAME-$CLUSTER_NAME_SUFFIX"
export SERVICE_TEMPLATE_NAME

step "Creating MultiClusterService '$MCS_NAME' (group=$CLD_GROUP_LABEL)"
MANIFEST="$WORKDIR/service-mcs.rendered.yaml"
envsubst < "$CONFIG_DIR/service-mcs.yaml" > "$MANIFEST"
cat "$MANIFEST"
kube apply -f "$MANIFEST"

step "Waiting for the ServiceSet from '$MCS_NAME'"
# KCM turns the MCS into a ServiceSet per matched cluster; if the selector is
# wrong nothing is ever created, which is the failure worth catching early.
# Filter on spec.multiClusterService, not spec.cluster: every ClusterDeployment
# already owns a ServiceSet of its own, which would match unconditionally.
elapsed=0
while (( elapsed < MCS_TIMEOUT )); do
    sset="$(kube get serviceset -n "$NAMESPACE" \
        -o jsonpath="{.items[?(@.spec.multiClusterService==\"$MCS_NAME\")].metadata.name}" 2>/dev/null || true)"
    if [[ -n "$sset" ]]; then
        log "ServiceSet: $sset"
        break
    fi
    if (( elapsed % 30 == 0 )); then
        log "⏳ No ServiceSet for '$CLD_NAME' yet (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done
if [[ -z "${sset:-}" ]]; then
    warn "No ServiceSet was created for '$CLD_NAME' -- check the MCS selector"
    kube get multiclusterservice "$MCS_NAME" -o yaml >&2 || true
    kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --show-labels >&2 || true
    exit 1
fi

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not verifying the workload in the child cluster"
else
    step "Waiting for '$SERVICE_NAME' to appear in the child cluster"
    [[ -f "$KUBECONFIG_CHILD" ]] \
        || die "No child kubeconfig at $KUBECONFIG_CHILD. Run ./scripts/check_child_cluster.sh first."

    elapsed=0
    while (( elapsed < MCS_TIMEOUT )); do
        if kube_child get namespace "$SERVICE_NAMESPACE" >/dev/null 2>&1; then
            break
        fi
        if (( elapsed % 30 == 0 )); then
            log "⏳ Namespace '$SERVICE_NAMESPACE' not in the child cluster yet (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    kube_child get namespace "$SERVICE_NAMESPACE" >/dev/null 2>&1 \
        || die "Namespace '$SERVICE_NAMESPACE' never appeared in the child cluster"

    KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE="$SERVICE_NAMESPACE" \
        WAIT_FOR_PODS="$SERVICE_NAME" "$SCRIPTS_DIR/wait_for_deployment.sh"

    kube_child get all -n "$SERVICE_NAMESPACE"
fi

kube get multiclusterservice "$MCS_NAME"
ok "Service '$SERVICE_NAME' deployed via MultiClusterService"
