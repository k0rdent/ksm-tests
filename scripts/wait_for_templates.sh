#!/bin/bash
set -euo pipefail

# Wait for the ProviderTemplates to become valid and the Release to go Ready.
# Validity means the chart was pulled, so this also proves the registry wiring.
#
# ClusterTemplates are deliberately not covered here: they stay invalid with
# "Waiting for Management creation" until a Management exists, which comes
# later. wait_for_management.sh checks those.

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

step "Waiting for ProviderTemplates to become valid"
for name in ${PROVIDER_TEMPLATES:-}; do
    wait_for_valid ProviderTemplate "$name" "" "$TEMPLATES_TIMEOUT"
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
