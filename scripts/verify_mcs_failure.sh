#!/bin/bash
set -euo pipefail

# Verify a scenario whose `expect:` block says the rollout must stop.
#
# Three separate claims, and all of them have to hold:
#   1. the service named in expect.failed reaches state Failed
#   2. expect.blocked services are never installed -- the graph stops there
#   3. expect.deployed services stay deployed -- KCM must not roll them back
#
# Called by deploy_mcs.sh with SERVICE_SET set; standalone it finds the
# ServiceSet itself, which is handy when re-checking a cluster by hand.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl jq
require_yq

check_scenario
expects_failure || die "Scenario '$SCENARIO' has no expect.failed -- nothing to verify"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

FAILED_SVC="$(expect_field failed)"
GRACE="$(expect_field graceSeconds)"
GRACE="${GRACE:-120}"

SERVICE_SET="${SERVICE_SET:-$(kube get serviceset -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.multiClusterService==\"$MCS_NAME\")].metadata.name}" 2>/dev/null || true)}"
[[ -n "$SERVICE_SET" ]] || die "No ServiceSet for MultiClusterService '$MCS_NAME'"

sset_json() {
    kube get serviceset "$SERVICE_SET" -n "$NAMESPACE" -o json 2>/dev/null || echo '{}'
}

# state_of NAME JSON -- the reported state, or empty if the service is not in
# the status at all. That is the normal case for a blocked service: KCM leaves
# it out of .status.services entirely rather than listing it as Pending, so an
# empty state here means "never got as far as being installed".
state_of() {
    jq -r --arg n "$1" '.status.services[]? | select(.name == $n) | .state // ""' <<< "$2"
}

failure_message_of() {
    jq -r --arg n "$1" '.status.services[]? | select(.name == $n) | .failureMessage // ""' <<< "$2"
}

dump_states() {
    jq -r '.status.services[]? | "    \(.name): \(.state)\(if .failureMessage != "" and .failureMessage != null then " -- " + .failureMessage else "" end)"' \
        <<< "$1"
}

# ── 1. The invalid service must fail ─────────────────────────────────────────
step "Scenario $SCENARIO: waiting for '$FAILED_SVC' to be stamped Failed"
elapsed=0
state=""
while (( elapsed < MCS_TIMEOUT )); do
    json="$(sset_json)"
    state="$(state_of "$FAILED_SVC" "$json")"
    [[ "$state" == "Failed" ]] && break
    # Deployed is terminal and wrong: the values were supposed to be rejected,
    # so the scenario is no longer testing what it claims to.
    if [[ "$state" == "Deployed" ]]; then
        dump_states "$json" >&2
        die "'$FAILED_SVC' deployed successfully -- the scenario's invalid values no longer fail"
    fi
    if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
        warn "'$FAILED_SVC' is '${state:-<unlisted>}' after ${elapsed}s -- diagnostics:"
        { dump_states "$json"; kcm_errors 5m; } >&2
    elif (( elapsed % 30 == 0 )); then
        log "⏳ '$FAILED_SVC' is '${state:-<unlisted>}' (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done

json="$(sset_json)"
if [[ "$(state_of "$FAILED_SVC" "$json")" != "Failed" ]]; then
    { dump_states "$json"; describe_stuck ServiceSet "$SERVICE_SET" "$NAMESPACE"; kcm_errors 20m; } >&2
    die "'$FAILED_SVC' never reached Failed (last state: '${state:-<unlisted>}')"
fi
ok "'$FAILED_SVC' is Failed"
msg="$(failure_message_of "$FAILED_SVC" "$json")"
[[ -n "$msg" ]] && log "   reason: $msg"

# The whole set must not claim success while one of its services is Failed.
deployed_flag="$(jq -r '.status.deployed // false' <<< "$json")"
[[ "$deployed_flag" == "false" ]] \
    || die "ServiceSet reports deployed=$deployed_flag despite '$FAILED_SVC' being Failed"
ok "ServiceSet is not marked deployed"

# ── 2. Nothing behind the failure may be installed ───────────────────────────
# Checked repeatedly over the grace window: a service that is merely slow would
# pass a single check taken too early.
step "Watching for ${GRACE}s that the blocked services stay uninstalled"
elapsed=0
while (( elapsed < GRACE )); do
    json="$(sset_json)"
    while read -r name; do
        [[ -n "$name" ]] || continue
        st="$(state_of "$name" "$json")"
        if [[ "$st" == "Deployed" ]]; then
            dump_states "$json" >&2
            die "'$name' was installed even though its dependency '$FAILED_SVC' failed"
        fi
    done < <(expect_list blocked)
    # Otherwise this window looks like a hang for its whole duration.
    (( elapsed % 30 == 0 )) && log "⏳ still blocked (${elapsed}/${GRACE}s)"
    sleep 10
    elapsed=$(( elapsed + 10 ))
done

json="$(sset_json)"
while read -r name; do
    [[ -n "$name" ]] || continue
    ns="$(service_field "$name" namespace)"
    log "── blocked: $name is '$(state_of "$name" "$json")' (namespace '$ns')"
    if [[ "${SKIP_CHILD_API_CHECK:-false}" != "true" ]]; then
        count="$(kube_child get deployments,daemonsets,statefulsets -n "$ns" \
            -o name 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$count" == "0" ]] \
            || { kube_child get all -n "$ns" >&2 || true
                 die "'$name' is blocked but left $count workload(s) in '$ns'"; }
    fi
done < <(expect_list blocked)
ok "Blocked services were never installed"

# ── 3. What was already deployed must survive ────────────────────────────────
step "Checking the services deployed before the failure were not rolled back"
while read -r name; do
    [[ -n "$name" ]] || continue

    # Not a single reading: a service that is merely being re-reconciled shows
    # up as Provisioning for a moment, and KCM itself treats that as transient
    # noise rather than a change. A rollback would leave it absent or Failed
    # and it would never come back, so give it a window to settle.
    settle=0
    st="$(state_of "$name" "$json")"
    while [[ "$st" != "Deployed" ]] && (( settle < ${KEPT_SETTLE:-180} )); do
        [[ "$st" == "Failed" ]] && { dump_states "$json" >&2
            die "'$name' is Failed -- it was rolled back after '$FAILED_SVC' failed"; }
        log "⏳ '$name' is '${st:-<unlisted>}', waiting for it to settle (${settle}s)"
        sleep 10
        settle=$(( settle + 10 ))
        json="$(sset_json)"
        st="$(state_of "$name" "$json")"
    done
    [[ "$st" == "Deployed" ]] \
        || { dump_states "$json" >&2
             die "'$name' never came back to Deployed (last state '${st:-<unlisted>}') -- it was rolled back after '$FAILED_SVC' failed"; }

    ns="$(service_field "$name" namespace)"
    if [[ "${SKIP_CHILD_API_CHECK:-false}" != "true" ]]; then
        count="$(kube_child get deployments,daemonsets,statefulsets -n "$ns" \
            -o name 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$count" != "0" ]] \
            || die "'$name' is Deployed but its workloads are gone from '$ns'"
        log "── kept: $name -- $count workload(s) in '$ns'"
        kube_child get pods -n "$ns" 2>/dev/null || true
    else
        log "── kept: $name is Deployed"
    fi
done < <(expect_list deployed)

step "Final ServiceSet state"
dump_states "$(sset_json)"
ok "Rollout stopped at '$FAILED_SVC', nothing behind it ran, nothing before it was rolled back"
