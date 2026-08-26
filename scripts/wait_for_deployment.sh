#!/bin/bash
set -euo pipefail

# Wait until every pod in $NAMESPACE is Ready.
#
#   NAMESPACE=kcm-system ./scripts/wait_for_deployment.sh
#   KUBECONFIG=./kcfg_docker NAMESPACE=kube-system ./scripts/wait_for_deployment.sh
#
# Optional:
#   WAIT_FOR_RUNNING=true    stop once all pods are Running (not necessarily Ready)
#   WAIT_FOR_CREATING=true   stop once all pods are at least ContainerCreating
#   WAIT_FOR_PODS="a b"      also require pods whose names contain these substrings
#   PODS_TIMEOUT=900         seconds before giving up
#
# Adapted from k0rdent/catalog's scripts/wait_for_deployment.sh.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd kubectl jq
require_env NAMESPACE

# Default to the management cluster unless the caller pointed us elsewhere.
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_MGMT}"

debug="${DEBUG:-}"
TIMEOUT="$PODS_TIMEOUT"
SECONDS=0
pods_json=""

step "Waiting for pods in namespace '$NAMESPACE' ($KUBECONFIG)"

while (( SECONDS < TIMEOUT )); do
    pods_json=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null || true)

    if [[ -z "$pods_json" ]]; then
        log "No pods found or error getting pods"
        sleep 3
        continue
    fi

    all_ready=true
    all_running=true
    all_creating=true

    pod_count=$(jq '.items | length' <<< "$pods_json")
    if [[ "$pod_count" -eq 0 ]]; then
        log "⏳ No pods in '$NAMESPACE' yet"
        sleep 3
        continue
    fi

    for row in $(jq -r '.items[] | @base64' <<< "$pods_json"); do
        _jq() { echo "${row}" | b64decode | jq -r "${1}"; }

        name=$(_jq '.metadata.name')
        status=$(_jq '.status.phase')
        pod_reason=$(_jq '.status.reason')
        reason=$(_jq '.status.containerStatuses[]?.state.waiting.reason')
        ready_containers=$(_jq 'if .status.containerStatuses != null then [.status.containerStatuses[] | select(.ready == true)] | length else 0 end')
        total_containers=$(_jq 'if .status.containerStatuses != null then .status.containerStatuses | length else 0 end')

        if [[ "$status" == "Succeeded" ]]; then
            continue
        elif [[ "$status" == "Failed" && "$pod_reason" == "Evicted" ]]; then
            # Terminal evicted pods get replaced by their controller; ignore them.
            continue
        elif [[ "$status" == "Running" ]]; then
            if [[ "$ready_containers" -ne "$total_containers" ]]; then
                all_ready=false
            fi
        else
            if [[ "$debug" == "true" || "$debug" == "1" ]]; then
                log "Pod '$name', status: '$status'"
                kubectl describe pod "$name" -n "$NAMESPACE" || true
            fi
            if [[ "$reason" != ContainerCreating ]]; then
                all_creating=false
            fi
            all_ready=false
            all_running=false
        fi
    done

    for wait_for_pod in ${WAIT_FOR_PODS:-}; do
        if ! jq -r '.items[].metadata.name' <<< "$pods_json" | grep -q "$wait_for_pod"; then
            all_ready=false
            all_running=false
            all_creating=false
            log "Expected pod '$wait_for_pod' not found!"
            break
        fi
    done

    if [[ "${WAIT_FOR_RUNNING:-}" == "true" ]]; then
        $all_running && { ok "All pods running in '$NAMESPACE'"; break; }
        log "⏳ Some pods are not running yet... (${SECONDS}s)"
    elif [[ "${WAIT_FOR_CREATING:-}" == "true" ]]; then
        $all_creating && { ok "All pods at least ContainerCreating in '$NAMESPACE'"; break; }
        log "⏳ Some pods are not creating yet... (${SECONDS}s)"
    else
        $all_ready && { ok "All pods are ready in '$NAMESPACE'"; break; }
        log "⏳ Some pods are not ready yet... (${SECONDS}s)"
    fi

    sleep 5
done

if (( SECONDS >= TIMEOUT )); then
    warn "Timeout after ${TIMEOUT}s: pods in '$NAMESPACE' are still not ready"
    kubectl get pods -n "$NAMESPACE" -o wide >&2 || true
    for row in $(jq -r '.items[] | @base64' <<< "$pods_json"); do
        _jq() { echo "${row}" | b64decode | jq -r "${1}"; }
        pod_name=$(_jq '.metadata.name')
        pod_phase=$(_jq '.status.phase')
        echo "📦 Pod: $pod_name (Phase: $pod_phase)" >&2
        container_count=$(_jq 'if .status.containerStatuses != null then .status.containerStatuses | length else 0 end')
        for (( i=0; i<container_count; i++ )); do
            cname=$(_jq ".status.containerStatuses[$i].name")
            ready=$(_jq ".status.containerStatuses[$i].ready")
            state=$(_jq ".status.containerStatuses[$i].state | keys[0]")
            creason=$(_jq ".status.containerStatuses[$i].state.${state}.reason // \"-\"")
            cmessage=$(_jq ".status.containerStatuses[$i].state.${state}.message // \"-\"")
            {
                echo " └─ Container: $cname"
                echo "    • Ready: $ready"
                echo "    • State: $state"
                echo "    • Reason: $creason"
                echo "    • Message: $cmessage"
            } >&2
        done
    done
    exit 1
fi
