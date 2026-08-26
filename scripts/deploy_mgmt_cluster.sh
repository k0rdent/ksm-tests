#!/bin/bash
set -euo pipefail

# Management cluster: a single k0s node in Docker. Writes $KUBECONFIG_MGMT.
#
# CAPD needs two extras: the host docker socket (it creates the node containers
# as siblings) and membership of $DOCKER_NETWORK, where it attaches them.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd docker kubectl

step "Deploying management cluster '$MGMT_CLUSTER_NAME'"

ensure_network "$DOCKER_NETWORK"

if container_running "$MGMT_CLUSTER_NAME"; then
    log "Management cluster container already running"
    # Reuse whatever port it was actually started with.
    MGMT_API_PORT="$(published_port "$MGMT_CLUSTER_NAME" 6443)"
    [[ -n "$MGMT_API_PORT" ]] || die "Container '$MGMT_CLUSTER_NAME' publishes no port for 6443"
    log "API published on 127.0.0.1:$MGMT_API_PORT"
else
    if container_exists "$MGMT_CLUSTER_NAME"; then
        log "Removing stale container '$MGMT_CLUSTER_NAME'"
        docker rm -vf "$MGMT_CLUSTER_NAME" >/dev/null
    fi

    if port_in_use "$MGMT_API_PORT"; then
        new_port="$(free_port "$MGMT_API_PORT")" \
            || die "No free port near $MGMT_API_PORT for the API server"
        warn "Port $MGMT_API_PORT is taken, using $new_port instead"
        MGMT_API_PORT="$new_port"
    fi

    log "Starting $K0S_IMAGE"
    docker run -d \
        --name "$MGMT_CLUSTER_NAME" \
        --hostname "$MGMT_CLUSTER_NAME" \
        --network "$DOCKER_NETWORK" \
        --privileged \
        -v /var/lib/k0s \
        -v /var/log/pods \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --tmpfs /run \
        -p "127.0.0.1:$MGMT_API_PORT:6443" \
        "$K0S_IMAGE" >/dev/null

    log "Waiting for the k0s admin kubeconfig..."
    until docker exec "$MGMT_CLUSTER_NAME" k0s kubeconfig admin >/dev/null 2>&1; do
        sleep 2
    done
fi

# hostPath mounts with propagation (used by the CAPD controller and by the CSI
# bits of the child clusters) need a recursively shared root. kind sets this up
# for its nodes; the plain k0s image does not.
docker exec "$MGMT_CLUSTER_NAME" mount --make-rshared /

step "Writing kubeconfig to $KUBECONFIG_MGMT"
docker exec "$MGMT_CLUSTER_NAME" k0s kubeconfig admin > "$KUBECONFIG_MGMT"
# k0s points the kubeconfig at the container's internal address; we reach the
# API through the published port instead.
sed -i.bak "s#server:.*#server: https://127.0.0.1:$MGMT_API_PORT#" "$KUBECONFIG_MGMT"
rm -f "$KUBECONFIG_MGMT.bak"
chmod 0600 "$KUBECONFIG_MGMT"

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
ok "Management cluster is ready (KUBECONFIG=$KUBECONFIG_MGMT)"
