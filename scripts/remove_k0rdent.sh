#!/bin/bash
# Remove one k0rdent test cluster: the containers, its kubeconfig and its
# build state. Best-effort, so it is safe to run twice or from a trap.
#
#   export KCM=1.12.0-rc.3            # required: which cluster
#   ./scripts/remove_k0rdent.sh
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_kcm

step "Removing k0rdent $KCM"

if command -v docker >/dev/null 2>&1; then
    for container in "$MGMT_CLUSTER_NAME" "$REGISTRY_NAME"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
            log "Removing container '$container'"
            docker rm -vf "$container" >/dev/null 2>&1
        fi
    done

    # Only remove the network if we are the last user; kind shares it.
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        attached="$(docker network inspect "$DOCKER_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' | tr -d ' ')"
        if [[ -z "$attached" ]]; then
            log "Removing docker network '$DOCKER_NETWORK'"
            docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1
        else
            log "Keeping network '$DOCKER_NETWORK' (still in use)"
        fi
    fi
fi

rm -f "$KUBECONFIG_NAMED" "$KUBECONFIG_NAMED.bak"
# Only if it is this cluster's: another environment may be the current one.
if [[ -L "$KUBECONFIG_MGMT" && ! -e "$KUBECONFIG_MGMT" ]]; then
    rm -f "$KUBECONFIG_MGMT"
fi

if [[ "${KEEP_WORKDIR:-false}" == "true" ]]; then
    log "Keeping $ENVDIR (KEEP_WORKDIR=true)"
else
    # The KCM checkout is the expensive part -- re-cloning costs minutes -- so
    # source mode keeps it and drops only the generated state.
    if [[ "$KCM_MODE" == "source" ]]; then
        rm -f "$ENVDIR"/*.yaml "$ENVDIR"/*.env 2>/dev/null
        log "Removed generated manifests from $ENVDIR (KCM checkout kept)"
    else
        rm -rf "$ENVDIR"
    fi
fi

ok "k0rdent $KCM removed"
