#!/bin/bash
set -euo pipefail

# The cluster KCM will adopt: a single k0s node in Docker, same recipe as the
# management cluster minus KCM itself.
#
# Two kubeconfigs come out of this, and the difference is the point:
#   $KUBECONFIG_CHILD          127.0.0.1:<published port>, used from the host
#   $WORKDIR/adopted-internal  the container IP, handed to KCM
# The host one is what makes this work on macOS, where an address inside the
# docker network is not routable.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"

require_cmd docker kubectl
ensure_workdir

step "Deploying the cluster to adopt: '$ADOPTED_CLUSTER_NAME'"

ensure_network "$DOCKER_NETWORK"

if container_running "$ADOPTED_CLUSTER_NAME"; then
    log "Container already running"
    ADOPTED_API_PORT="$(published_port "$ADOPTED_CLUSTER_NAME" 6443)"
    [[ -n "$ADOPTED_API_PORT" ]] || die "Container '$ADOPTED_CLUSTER_NAME' publishes no port for 6443"
    log "API published on 127.0.0.1:$ADOPTED_API_PORT"
else
    if container_exists "$ADOPTED_CLUSTER_NAME"; then
        log "Removing stale container '$ADOPTED_CLUSTER_NAME'"
        docker rm -vf "$ADOPTED_CLUSTER_NAME" >/dev/null
    fi

    if port_in_use "$ADOPTED_API_PORT"; then
        new_port="$(free_port "$ADOPTED_API_PORT")" \
            || die "No free port near $ADOPTED_API_PORT for the adopted API server"
        warn "Port $ADOPTED_API_PORT is taken, using $new_port instead"
        ADOPTED_API_PORT="$new_port"
    fi

    log "Starting $K0S_IMAGE"
    docker run -d \
        --name "$ADOPTED_CLUSTER_NAME" \
        --hostname "$ADOPTED_CLUSTER_NAME" \
        --network "$DOCKER_NETWORK" \
        --privileged \
        -v /var/lib/k0s \
        -v /var/log/pods \
        --tmpfs /run \
        -p "127.0.0.1:$ADOPTED_API_PORT:6443" \
        "$K0S_IMAGE" >/dev/null

    log "Waiting for the k0s admin kubeconfig..."
    until docker exec "$ADOPTED_CLUSTER_NAME" k0s kubeconfig admin >/dev/null 2>&1; do
        sleep 2
    done
fi

# Charts deployed here mount volumes, so the root has to be shared for the same
# reason as on the management cluster.
docker exec "$ADOPTED_CLUSTER_NAME" mount --make-rshared /

step "Writing the two kubeconfigs"
INTERNAL_KUBECONFIG="$WORKDIR/adopted-internal.kubeconfig"

# By IP, not by container name: k0s issues the API certificate for the node
# address and localhost, so the hostname is not a SAN and sveltos would fail
# the TLS check.
ADOPTED_IP="$(container_ip "$ADOPTED_CLUSTER_NAME" "$DOCKER_NETWORK")"
[[ -n "$ADOPTED_IP" ]] || die "Could not read the address of '$ADOPTED_CLUSTER_NAME' on '$DOCKER_NETWORK'"
docker exec "$ADOPTED_CLUSTER_NAME" k0s kubeconfig admin \
    | sed "s#server:.*#server: https://$ADOPTED_IP:6443#" > "$INTERNAL_KUBECONFIG"
chmod 0600 "$INTERNAL_KUBECONFIG"
log "for KCM:  $INTERNAL_KUBECONFIG  (https://$ADOPTED_IP:6443)"

docker exec "$ADOPTED_CLUSTER_NAME" k0s kubeconfig admin \
    | sed "s#server:.*#server: https://127.0.0.1:$ADOPTED_API_PORT#" > "$KUBECONFIG_CHILD"
chmod 0600 "$KUBECONFIG_CHILD"
log "for the harness: $KUBECONFIG_CHILD  (https://127.0.0.1:$ADOPTED_API_PORT)"

echo "ADOPTED_API_PORT=$ADOPTED_API_PORT" > "$WORKDIR/adopted.env"

step "Waiting for the node to come up"
until kubectl --kubeconfig "$KUBECONFIG_CHILD" get pods -n kube-system --no-headers 2>/dev/null | grep -q .; do
    sleep 2
done
until kubectl --kubeconfig "$KUBECONFIG_CHILD" wait -n kube-system \
        --for=condition=Ready pod --all --timeout=2s >/dev/null 2>&1; do
    kubectl --kubeconfig "$KUBECONFIG_CHILD" get pods -n kube-system || true
    sleep 5
done

# Single node: everything has to be schedulable on the control plane.
kubectl --kubeconfig "$KUBECONFIG_CHILD" taint nodes "$ADOPTED_CLUSTER_NAME" \
    node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

kubectl --kubeconfig "$KUBECONFIG_CHILD" get nodes
ok "Cluster to adopt is ready"
