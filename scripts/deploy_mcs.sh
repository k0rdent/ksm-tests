#!/bin/bash
set -euo pipefail

# Deploy every service in $SERVICES_FILE to the child cluster through a single
# MultiClusterService, then verify they actually landed there -- an MCS
# reporting success is not proof the workloads are running.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl helm jq
require_yq

check_scenario

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

MANIFEST="$WORKDIR/service-mcs.rendered.yaml"
render_mcs "$MANIFEST" initial

step "Scenario $SCENARIO: creating MultiClusterService '$MCS_NAME' (group=$CLD_GROUP_LABEL)"
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
    if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
        warn "No ServiceSet for '$MCS_NAME' after ${elapsed}s -- diagnostics:"
        kcm_errors 5m >&2
    elif (( elapsed % 30 == 0 )); then
        log "⏳ No ServiceSet for '$MCS_NAME' yet (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done
if [[ -z "${sset:-}" ]]; then
    warn "No ServiceSet was created for '$MCS_NAME' -- check the MCS selector"
    kube get multiclusterservice "$MCS_NAME" -o yaml >&2 || true
    kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --show-labels >&2 || true
    kcm_errors 20m >&2 || true
    exit 1
fi

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not verifying the workloads in the child cluster"
    kube get multiclusterservice "$MCS_NAME"
    ok "MultiClusterService '$MCS_NAME' created"
    exit 0
fi

# Scenarios that assert the rollout stops have their own checks: waiting for
# every service to be Ready would just time out on the one meant to fail.
if expects_failure; then
    SERVICE_SET="$sset" exec "$SCRIPTS_DIR/verify_mcs_failure.sh"
fi

[[ -f "$KUBECONFIG_CHILD" ]] \
    || die "No child kubeconfig at $KUBECONFIG_CHILD. Run ./scripts/check_child_cluster.sh first."

step "Waiting for the workloads in the child cluster"
while IFS="$SERVICE_SEP" read -r name _chart _version _repo namespace _dep waitfor; do
    [[ -n "$name" ]] || continue
    # Services without a waitForPods only ship CRDs or config, so there is
    # nothing to wait for beyond the namespace.
    log "── $name -> namespace '$namespace'"

    # The helm release, not the namespace: namespaces linger after a previous
    # scenario, so "namespace exists" passes instantly and would never catch a
    # service that was not installed at all.
    if ! wait_release "$name" "$namespace" "$MCS_TIMEOUT"; then
        { describe_stuck MultiClusterService "$MCS_NAME" ""; kcm_errors 20m; } >&2
        die "Service '$name' has no deployed helm release in the child cluster"
    fi

    [[ -n "$waitfor" ]] || { log "no waitForPods for '$name', namespace is enough"; continue; }

    KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE="$namespace" \
        WAIT_FOR_PODS="$waitfor" "$SCRIPTS_DIR/wait_for_deployment.sh"
done < <(services_rows)

step "Deployed workloads"
while read -r ns; do
    [[ -n "$ns" ]] || continue
    echo "── $ns"
    kube_child get pods -n "$ns" 2>/dev/null || true
done < <(service_namespaces)

kube get multiclusterservice "$MCS_NAME"
ok "All services deployed via MultiClusterService"
