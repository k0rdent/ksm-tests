#!/usr/bin/env bash
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
#   POD_TICK_INTERVAL=30     seconds between heartbeats while nothing changes
#
# While it waits it prints what is actually there -- every pod, its phase, how
# many of its containers are ready and why the rest are not. In full on the
# first poll and once more at the end; in between only the pods that moved. A
# cluster coming up then tells its own story instead of a line saying only
# that it has not finished.
#
# Adapted from k0rdent/catalog's scripts/wait_for_deployment.sh.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd kubectl jq
require_env NAMESPACE

# Default to the management cluster unless the caller pointed us elsewhere.
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_MGMT}"

debug="${DEBUG:-}"
TIMEOUT="$PODS_TIMEOUT"
POD_TICK_INTERVAL="${POD_TICK_INTERVAL:-30}"
SECONDS=0
pods_json=""
last_summary=""
last_tick=0

# pod_summary -- one line per pod: name, phase, ready containers, and the
# waiting or terminated reason behind the ones that are not. Sorted, so a
# reordering by the API server does not read as a change.
pod_summary() {
    jq -r '
      .items[] as $p
      | (($p.status.containerStatuses // [])) as $cs
      | ( [ $cs[] | (.state.waiting.reason // .state.terminated.reason // empty) ]
          | unique | join(",") ) as $r
      | [ $p.metadata.name,
          ($p.status.phase // "-"),
          (([ $cs[] | select(.ready == true) ] | length | tostring)
             + "/" + ($cs | length | tostring)),
          (if $r == "" then "-" else $r end)
        ] | @tsv' <<< "$1" | sort
}

# pod_table -- pod_summary's output, aligned. Printed in full on the first
# poll and again at the end; in between only what moved, see pod_changes.
pod_table() {
    [[ -n "$1" ]] || return 0
    awk -F'\t' '{ printf "      %-46s %-10s %-6s %s\n", $1, $2, $3, $4 }' <<< "$1"
}

# pod_changes NOW BEFORE -- the rows that differ from the last poll: pods that
# changed state, pods that appeared, and pods that are no longer there. A
# cluster coming up is mostly pods that already settled, and reprinting thirty
# Running 1/1 lines every five seconds buries the one that did move.
#
# comm rather than an associative array, so this still runs under the bash 3.2
# that macOS ships. Both sides are sorted by pod_summary, and the name is the
# first field, so cutting it keeps that order.
pod_changes() {
    {
        comm -13 <(printf '%s\n' "$2") <(printf '%s\n' "$1")
        comm -13 <(printf '%s\n' "$1" | cut -f1) <(printf '%s\n' "$2" | cut -f1) \
            | sed 's/$/\tgone\t-\t-/'
    } | sort
}

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

    summary="$(pod_summary "$pods_json")"
    # A pod with no container statuses yet is not ready, so it must not count
    # as 0/0 "all ready".
    ready_pods="$(jq '[ .items[]
        | (.status.containerStatuses // []) as $cs
        | select(($cs | length) > 0
                 and ([ $cs[] | select(.ready == true) ] | length) == ($cs | length))
      ] | length' <<< "$pods_json")"

    if [[ "${WAIT_FOR_RUNNING:-}" == "true" ]]; then
        $all_running && { ok "All pods running in '$NAMESPACE'"; pod_table "$summary"; break; }
        waiting_for="running"
    elif [[ "${WAIT_FOR_CREATING:-}" == "true" ]]; then
        $all_creating && { ok "All pods at least ContainerCreating in '$NAMESPACE'"; pod_table "$summary"; break; }
        waiting_for="creating"
    else
        $all_ready && { ok "All pods are ready in '$NAMESPACE'"; pod_table "$summary"; break; }
        waiting_for="ready"
    fi

    # Everything the first time, only what moved after that, a heartbeat when
    # nothing did: a provisioning cluster changes often enough to follow, and a
    # stuck one must not scroll the reason for being stuck off the top.
    if [[ "$summary" != "$last_summary" ]]; then
        log "⏳ waiting for pods to be $waiting_for -- $ready_pods/$pod_count ready (${SECONDS}s)"
        if [[ -z "$last_summary" ]]; then
            pod_table "$summary"
        else
            pod_table "$(pod_changes "$summary" "$last_summary")"
        fi
        last_summary="$summary"
        last_tick=$SECONDS
    elif (( SECONDS - last_tick >= POD_TICK_INTERVAL )); then
        log "⏳ unchanged -- $ready_pods/$pod_count ready (${SECONDS}s)"
        last_tick=$SECONDS
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
