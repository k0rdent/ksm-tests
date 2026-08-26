#!/bin/bash
set -euo pipefail

# Wait for the applied templates to become valid and the Release to go Ready.
# Validity means the chart was pulled, so this also proves the registry wiring.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl

RELEASE_ENV="$WORKDIR/release.env"
[[ -f "$RELEASE_ENV" ]] || die "$RELEASE_ENV not found. Run ./scripts/apply_release.sh first."
# shellcheck source=/dev/null
source "$RELEASE_ENV"

export KUBECONFIG="$KUBECONFIG_MGMT"

# wait_template KIND NAME [NAMESPACE]
wait_template() {
    local kind="$1" name="$2" ns="${3:-}"
    local elapsed=0 valid=""
    local args=(get "$kind" "$name")
    [[ -n "$ns" ]] && args+=(-n "$ns")
    args+=(-o 'jsonpath={.status.valid}')

    while (( elapsed < TEMPLATES_TIMEOUT )); do
        valid="$(kube "${args[@]}" 2>/dev/null || true)"
        if [[ "$valid" == "true" ]]; then
            log "✅ $kind/$name is valid"
            return 0
        fi
        if (( elapsed % 30 == 0 )); then
            log "⏳ $kind/$name valid='${valid:-<none>}' (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    warn "Timeout waiting for $kind/$name to become valid"
    local dump=(get "$kind" "$name")
    [[ -n "$ns" ]] && dump+=(-n "$ns")
    dump+=(-o yaml)
    kube "${dump[@]}" >&2 || true
    return 1
}

step "Waiting for ProviderTemplates to become valid"
for name in ${PROVIDER_TEMPLATES:-}; do
    wait_template ProviderTemplate "$name"
done

step "Waiting for ClusterTemplates to become valid"
for name in ${CLUSTER_TEMPLATES:-}; do
    wait_template ClusterTemplate "$name" "$NAMESPACE"
done

step "Waiting for Release '$RELEASE_NAME' to become Ready"
elapsed=0
while (( elapsed < TEMPLATES_TIMEOUT )); do
    ready="$(kube get release "$RELEASE_NAME" -o 'jsonpath={.status.ready}' 2>/dev/null || true)"
    if [[ "$ready" == "true" ]]; then
        ok "Release '$RELEASE_NAME' is Ready"
        exit 0
    fi
    if (( elapsed % 30 == 0 )); then
        log "⏳ Release ready='${ready:-<none>}' (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done

warn "Timeout waiting for Release '$RELEASE_NAME' to become Ready"
kube get release "$RELEASE_NAME" -o yaml >&2 || true
exit 1
