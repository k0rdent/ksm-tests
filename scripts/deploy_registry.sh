#!/bin/bash
set -euo pipefail

# Local OCI registry for KCM's template charts. Shares the cluster's docker
# network, so the controller reaches it by name while we push via localhost.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"

require_cmd docker

step "Deploying local OCI registry '$REGISTRY_NAME'"

ensure_network "$DOCKER_NETWORK"

if container_running "$REGISTRY_NAME"; then
    log "Registry '$REGISTRY_NAME' is already running"
elif container_exists "$REGISTRY_NAME"; then
    log "Starting existing registry container '$REGISTRY_NAME'"
    docker start "$REGISTRY_NAME" >/dev/null
else
    port_in_use "$REGISTRY_PORT" \
        && die "Port $REGISTRY_PORT is already in use. Set REGISTRY_PORT to a free one."
    docker run -d --restart=always \
        --name "$REGISTRY_NAME" \
        --network "$DOCKER_NETWORK" \
        -p "127.0.0.1:$REGISTRY_PORT:5000" \
        "$REGISTRY_IMAGE" >/dev/null
    log "Started $REGISTRY_IMAGE as '$REGISTRY_NAME'"
fi

connect_network "$DOCKER_NETWORK" "$REGISTRY_NAME"

log "Waiting for the registry to answer on 127.0.0.1:$REGISTRY_PORT"
MAX_RETRIES=30 SLEEP=2 "$SCRIPTS_DIR/retry.sh" \
    curl -fsS "http://127.0.0.1:$REGISTRY_PORT/v2/" -o /dev/null

ok "Registry ready: push to $REGISTRY_REPO, cluster reads $TEMPLATES_REPO_URL"
