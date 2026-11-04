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

# A run starts here, so the ledger does too -- otherwise a second run in the
# same checkout would report both.
rm -f "$TIMINGS_FILE"
time_phase "$(k0rdent_label)"

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

# The shared wait, not a loop of our own: it holds the one definition of what
# "ready" means, it bounds the wait, and on a cluster that never comes up it
# says which container is stuck and why. It also handles the namespace being
# empty at first, which is what the appear-then-ready pair here used to do.
NAMESPACE=kube-system "$SCRIPTS_DIR/utils/wait_for_deployment.sh"

# Single-node cluster: everything has to run on the control plane.
kube taint nodes "$MGMT_CLUSTER_NAME" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

kube get nodes
ok "Management cluster is ready"
# Copy-pasteable from the repo root, where you ran make. Absolute only if the
# kubeconfig was pointed somewhere else.
log "export KUBECONFIG=${KUBECONFIG_MGMT#"$PROJECT_ROOT"/}"
