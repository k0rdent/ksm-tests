#!/bin/bash
set -euo pipefail

# Prove the child is a real, usable cluster -- not just a ClusterDeployment
# whose Ready condition flipped.
#
# The child kubeconfig points at a NodePort on the docker network: routable
# from a Linux host, not from macOS. Set SKIP_CHILD_API_CHECK=true there.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl jq

export KUBECONFIG="$KUBECONFIG_MGMT"

step "Checking the CAPI objects for '$CLD_NAME'"
kube get cluster "$CLD_NAME" -n "$NAMESPACE" -o wide
kube get machines -n "$NAMESPACE" -o wide

not_running="$(kube get machines -n "$NAMESPACE" -o json \
    | jq -r --arg c "$CLD_NAME" \
        '.items[] | select(.spec.clusterName == $c) | select(.status.phase != "Running") | .metadata.name')"
[[ -z "$not_running" ]] || die "Machines not in phase Running: $(echo "$not_running" | tr '\n' ' ')"
ok "All Machines are Running"

step "Extracting the child cluster kubeconfig"
SECRET_NAME="$CLD_NAME-kubeconfig"
resource_exists secret "$SECRET_NAME" "$NAMESPACE" || die "Secret '$SECRET_NAME' not found in '$NAMESPACE'"
kube get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.value}' | base64 -d > "$KUBECONFIG_CHILD"
chmod 0600 "$KUBECONFIG_CHILD"
log "Wrote $KUBECONFIG_CHILD"

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not talking to the child API"
    exit 0
fi

step "Talking to the child cluster API"
MAX_RETRIES=30 SLEEP=10 "$SCRIPTS_DIR/retry.sh" \
    kubectl --kubeconfig "$KUBECONFIG_CHILD" get --raw /healthz

step "Waiting for the child nodes to become Ready"
elapsed=0
while (( elapsed < PODS_TIMEOUT )); do
    ready_nodes="$(kube_child get nodes -o json 2>/dev/null \
        | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length' \
        2>/dev/null || echo 0)"
    if [[ "$ready_nodes" -ge "$WORKERS_NUMBER" ]]; then
        ok "$ready_nodes node(s) Ready (expected at least $WORKERS_NUMBER)"
        break
    fi
    if (( elapsed % 30 == 0 )); then
        log "⏳ $ready_nodes/$WORKERS_NUMBER node(s) Ready (${elapsed}s)"
        kube_child get nodes 2>/dev/null || true
    fi
    sleep 10
    elapsed=$(( elapsed + 10 ))
done

if (( elapsed >= PODS_TIMEOUT )); then
    warn "Timeout waiting for child nodes to become Ready"
    kube_child get nodes -o wide >&2 || true
    exit 1
fi

kube_child get nodes -o wide

step "Waiting for the child kube-system pods"
KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE=kube-system "$SCRIPTS_DIR/wait_for_deployment.sh"

ok "Child cluster '$CLD_NAME' is healthy"
