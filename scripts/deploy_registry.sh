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

ensure_workdir

if container_running "$REGISTRY_NAME" || container_exists "$REGISTRY_NAME"; then
    if ! container_running "$REGISTRY_NAME"; then
        log "Starting existing registry container '$REGISTRY_NAME'"
        docker start "$REGISTRY_NAME" >/dev/null
    else
        log "Registry '$REGISTRY_NAME' is already running"
    fi
    # Reuse whatever port it was started with.
    REGISTRY_PORT="$(published_port "$REGISTRY_NAME" 5000)"
    [[ -n "$REGISTRY_PORT" ]] || die "Container '$REGISTRY_NAME' publishes no port for 5000"
else
    if port_in_use "$REGISTRY_PORT"; then
        new_port="$(free_port "$REGISTRY_PORT")" \
            || die "No free port near $REGISTRY_PORT for the registry"
        warn "Port $REGISTRY_PORT is taken, using $new_port instead"
        REGISTRY_PORT="$new_port"
    fi
    docker run -d --restart=always \
        --name "$REGISTRY_NAME" \
        --network "$DOCKER_NETWORK" \
        -p "127.0.0.1:$REGISTRY_PORT:5000" \
        "$REGISTRY_IMAGE" >/dev/null
    log "Started $REGISTRY_IMAGE as '$REGISTRY_NAME'"
fi

connect_network "$DOCKER_NETWORK" "$REGISTRY_NAME"

REGISTRY_REPO="oci://127.0.0.1:$REGISTRY_PORT/charts"

log "Waiting for the registry to answer on 127.0.0.1:$REGISTRY_PORT"
MAX_RETRIES=30 SLEEP=2 "$SCRIPTS_DIR/retry.sh" \
    curl -fsS "http://127.0.0.1:$REGISTRY_PORT/v2/" -o /dev/null

# The port may differ from the default, so record it for push_kcm_artifacts.sh.
{
    echo "REGISTRY_PORT=$REGISTRY_PORT"
    echo "REGISTRY_REPO=$REGISTRY_REPO"
} > "$WORKDIR/registry.env"

ok "Registry ready: push to $REGISTRY_REPO, cluster reads $TEMPLATES_REPO_URL"
