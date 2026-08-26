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
    return 1
}

# wait_for_absence KIND NAME NAMESPACE TIMEOUT_SECONDS [POLL_SECONDS]
wait_for_absence() {
    local kind="$1" name="$2" ns="$3" timeout="$4" poll="${5:-5}"
    local elapsed=0

    log "Waiting for $kind/$name to disappear (timeout ${timeout}s)"
    while (( elapsed < timeout )); do
        if ! resource_exists "$kind" "$name" "$ns"; then
            ok "$kind/$name is gone"
            return 0
        fi
        if (( elapsed % 30 == 0 )); then
            log "⏳ $kind/$name still present (${elapsed}s elapsed)"
        fi
        sleep "$poll"
        elapsed=$(( elapsed + poll ))
    done

    warn "Timeout after ${timeout}s waiting for $kind/$name to be removed"
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")
    args+=(-o yaml)
    kube "${args[@]}" 2>/dev/null >&2 || true
    return 1
}
