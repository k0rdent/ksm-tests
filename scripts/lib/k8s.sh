#!/bin/bash
# kubectl helpers. Expects scripts/lib/common.sh to be sourced first.

# kube ... -- kubectl against the management cluster.
kube() {
    kubectl --kubeconfig "$KUBECONFIG_MGMT" "$@"
}

# kube_child ... -- kubectl against the deployed child cluster.
kube_child() {
    kubectl --kubeconfig "$KUBECONFIG_CHILD" "$@"
}

# require_cluster -- fail loudly if the API is unreachable. Without this a
# "does not exist, nothing to do" check silently passes against a dead cluster.
require_cluster() {
    [[ -f "$KUBECONFIG_MGMT" ]] || die "No kubeconfig at $KUBECONFIG_MGMT"
    kube version --request-timeout=10s >/dev/null 2>&1 \
        || die "Cannot reach the management cluster API using $KUBECONFIG_MGMT"
}

# resource_exists KIND NAME [NAMESPACE]
resource_exists() {
    local kind="$1" name="$2" ns="${3:-}"
    if [[ -n "$ns" ]]; then
        kube get "$kind" "$name" -n "$ns" >/dev/null 2>&1
    else
        kube get "$kind" "$name" >/dev/null 2>&1
    fi
}

# condition_status KIND NAME NAMESPACE TYPE -- prints True/False/"" for a
# status.conditions entry. Never fails, so it is safe inside `until` loops.
condition_status() {
    local kind="$1" name="$2" ns="$3" type="$4"
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")
    args+=(-o "jsonpath={.status.conditions[?(@.type==\"$type\")].status}")
    kube "${args[@]}" 2>/dev/null || true
}

# wait_for_condition KIND NAME NAMESPACE TYPE TIMEOUT_SECONDS [POLL_SECONDS]
#
# Polls until the condition reports True. On timeout it dumps the object's
# conditions -- that dump is usually the whole diagnosis, so keep it.
wait_for_condition() {
    local kind="$1" name="$2" ns="$3" type="$4" timeout="$5" poll="${6:-5}"
    local elapsed=0 status=""

    log "Waiting for $kind/$name condition $type=True (timeout ${timeout}s)"
    while (( elapsed < timeout )); do
        status="$(condition_status "$kind" "$name" "$ns" "$type")"
        if [[ "$status" == "True" ]]; then
            ok "$kind/$name is $type"
            return 0
        fi
        if (( elapsed % 30 == 0 )); then
            log "⏳ $kind/$name $type='${status:-<none>}' (${elapsed}s elapsed)"
        fi
        sleep "$poll"
        elapsed=$(( elapsed + poll ))
    done

    warn "Timeout after ${timeout}s waiting for $kind/$name $type=True"
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")
    args+=(-o yaml)
    kube "${args[@]}" 2>/dev/null | sed -n '/^status:/,$p' >&2 || true
    kcm_errors 20m >&2 || true
    return 1
}

# wait_for_valid KIND NAME NAMESPACE TIMEOUT_SECONDS [POLL_SECONDS]
# Templates expose readiness as status.valid rather than a condition.
wait_for_valid() {
    local kind="$1" name="$2" ns="$3" timeout="$4" poll="${5:-5}"
    local elapsed=0 valid="" err=""
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")

    while (( elapsed < timeout )); do
        valid="$(kube "${args[@]}" -o 'jsonpath={.status.valid}' 2>/dev/null || true)"
        if [[ "$valid" == "true" ]]; then
            log "✅ $kind/$name is valid"
            return 0
        fi
        if (( elapsed % 30 == 0 )); then
            err="$(kube "${args[@]}" -o 'jsonpath={.status.validationError}' 2>/dev/null || true)"
            log "⏳ $kind/$name valid='${valid:-<none>}' ${err:+($err)} (${elapsed}s)"
        fi
        sleep "$poll"
        elapsed=$(( elapsed + poll ))
    done

    warn "Timeout after ${timeout}s waiting for $kind/$name to become valid"
    kube "${args[@]}" -o yaml >&2 || true
    kcm_errors 20m >&2 || true
    return 1
}

# kcm_errors [SINCE] -- warning events and error log lines from the controllers,
# printed straight into the CI log. A stuck finalizer says nothing by itself;
# the reason is almost always in here.
kcm_errors() {
    local since="${1:-10m}"

    echo "── Warning events (last $since)"
    kube get events -A --field-selector type=Warning \
        --sort-by=.lastTimestamp -o custom-columns=\
'TIME:.lastTimestamp,NS:.metadata.namespace,OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message' \
        2>/dev/null | tail -25 || true

    local ns pod
    for ns in "$NAMESPACE" projectsveltos; do
        kube get namespace "$ns" >/dev/null 2>&1 || continue
        while read -r pod; do
            [[ -n "$pod" ]] || continue
            local hits
            # Go's logger wraps long errors as `err=<` ... `>` across several
            # lines. Matching line by line drops the body, which is where the
            # actual reason lives -- keep the continuation lines too.
            hits="$(kube logs -n "$ns" "$pod" --all-containers --since="$since" 2>/dev/null \
                | awk '
                    /"level":"error"|level=error|^E[0-9]{4} |[Ee]rror|failed/ {
                        print; if ($0 ~ /err=<[[:space:]]*$/) inblock=1; next
                    }
                    inblock { print; if ($0 ~ /^[[:space:]]*>/) inblock=0 }
                  ' \
                | grep -viE 'errors?\.go|no error|error_|errorf' \
                | tail -20 || true)"
            [[ -n "$hits" ]] || continue
            echo "── $ns/${pod#pod/}"
            cut -c1-400 <<< "$hits"
        done < <(kube get pods -n "$ns" -o name 2>/dev/null)
    done
}

# describe_stuck KIND NAME NAMESPACE -- why an object will not go away.
describe_stuck() {
    local kind="$1" name="$2" ns="$3"
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")

    echo "── $kind/$name finalizers and status"
    kube "${args[@]}" -o jsonpath='{"finalizers: "}{.metadata.finalizers}{"\ndeletionTimestamp: "}{.metadata.deletionTimestamp}{"\n"}' 2>/dev/null || true
    kube "${args[@]}" -o yaml 2>/dev/null | sed -n '/^status:/,$p' | head -40 || true

    echo "── ServiceSets"
    kube get servicesets -A -o wide 2>/dev/null || true
    echo "── HelmReleases"
    kube get helmreleases -A 2>/dev/null || true
}

# wait_for_absence KIND NAME NAMESPACE TIMEOUT_SECONDS [POLL_SECONDS]
#
# Every DIAG_INTERVAL seconds of waiting it dumps why the object is stuck, so a
# CI log shows the reason instead of a wall of identical "still present" lines.
wait_for_absence() {
    local kind="$1" name="$2" ns="$3" timeout="$4" poll="${5:-5}"
    local elapsed=0
    local diag_every="${DIAG_INTERVAL:-120}"

    log "Waiting for $kind/$name to disappear (timeout ${timeout}s)"
    while (( elapsed < timeout )); do
        if ! resource_exists "$kind" "$name" "$ns"; then
            ok "$kind/$name is gone"
            return 0
        fi
        if (( elapsed > 0 && elapsed % diag_every == 0 )); then
            warn "$kind/$name still present after ${elapsed}s -- diagnostics:"
            { describe_stuck "$kind" "$name" "$ns"; kcm_errors 5m; } >&2
        elif (( elapsed % 30 == 0 )); then
            log "⏳ $kind/$name still present (${elapsed}s elapsed)"
        fi
        sleep "$poll"
        elapsed=$(( elapsed + poll ))
    done

    warn "Timeout after ${timeout}s waiting for $kind/$name to be removed"
    { describe_stuck "$kind" "$name" "$ns"; kcm_errors 20m; } >&2
    return 1
}
