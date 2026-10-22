#!/usr/bin/env bash
set -euo pipefail

# The k0rdent cluster itself: a single k0s node in Docker. Writes
# $KUBECONFIG_NAMED and points $KUBECONFIG_MGMT (./kcfg_k0rdent) at it.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd docker kubectl

step "Deploying management cluster '$MGMT_CLUSTER_NAME'"

ensure_network "$DOCKER_NETWORK"

start_k0s_container "$MGMT_CLUSTER_NAME" "$MGMT_API_PORT"
MGMT_API_PORT="$K0S_API_PORT"

step "Writing kubeconfig to $KUBECONFIG_NAMED"
# We reach the API through the published port.
write_k0s_kubeconfig "$MGMT_CLUSTER_NAME" "https://127.0.0.1:$MGMT_API_PORT" "$KUBECONFIG_NAMED"

# kcfg_k0rdent is whichever cluster the scenario scripts will talk to. A link,
# so switching environments is one ln and `ls -l` says which one is current.
ln -sfn "$(basename "$KUBECONFIG_NAMED")" "$KUBECONFIG_MGMT"

step "Waiting for the node to come up"
log "Waiting for kube-system pods to appear..."
until kube get pods -n kube-system --no-headers 2>/dev/null | grep -q .; do
    sleep 2
done

log "Waiting for kube-system pods to become Ready..."
until kube wait -n kube-system --for=condition=Ready pod --all --timeout=2s >/dev/null 2>&1; do
    kube get pods -n kube-system || true
    sleep 5
done

# Single-node cluster: everything has to run on the control plane.
kube taint nodes "$MGMT_CLUSTER_NAME" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

kube get nodes
ok "Management cluster is ready"
# Copy-pasteable from the repo root, where you ran make. Absolute only if the
# kubeconfig was pointed somewhere else.
log "export KUBECONFIG=${KUBECONFIG_MGMT#"$PROJECT_ROOT"/}"
