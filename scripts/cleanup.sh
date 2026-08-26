#!/bin/bash
# Tear the environment down. Best-effort: keep going even when pieces are
# already gone, so this is safe to run from a trap or `if: always()`.
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

step "Cleaning up"

if command -v docker >/dev/null 2>&1; then
    # CAPD node containers first -- they are children of the management cluster.
    orphans="$(docker ps -a --filter "name=^$CLD_NAME-" --format '{{.Names}}')"
    if [[ -n "$orphans" ]]; then
        log "Removing CAPD containers: $(echo "$orphans" | tr '\n' ' ')"
        # shellcheck disable=SC2086 # deliberate word splitting of the name list
        docker rm -vf $orphans >/dev/null 2>&1
    fi

    for container in "$MGMT_CLUSTER_NAME" "$REGISTRY_NAME"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
            log "Removing container '$container'"
            docker rm -vf "$container" >/dev/null 2>&1
        fi
    done

    # Only remove the network if we are the last user; CAPD and kind share it.
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

rm -f "$KUBECONFIG_MGMT" "$KUBECONFIG_CHILD" "$KUBECONFIG_MGMT.bak"

if [[ "${KEEP_WORKDIR:-false}" == "true" ]]; then
    log "Keeping $WORKDIR (KEEP_WORKDIR=true)"
else
    # The KCM checkout is the expensive part; keep it unless it was ours to
    # begin with... it is, but re-cloning costs minutes, so only drop the
    # generated state.
    rm -f "$WORKDIR"/*.yaml "$WORKDIR"/*.env 2>/dev/null
    log "Removed generated manifests from $WORKDIR (KCM checkout kept)"
fi

ok "Cleanup done"
