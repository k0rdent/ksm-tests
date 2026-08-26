#!/bin/bash
set -euo pipefail

# Wait for the Management object to report Ready, then sanity-check that the
# providers we asked for are the ones that actually got installed.
#
# Management goes Ready only after every enabled provider's HelmRelease has
# converged, so this is the real "KCM is up" gate.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl

export KUBECONFIG="$KUBECONFIG_MGMT"

step "Waiting for Management 'kcm' to become Ready"
resource_exists Management kcm || die "Management 'kcm' does not exist. Run ./scripts/apply_management.sh first."

if ! wait_for_condition Management kcm "" Ready "$MANAGEMENT_TIMEOUT"; then
    warn "Components reported by the Management object:"
    kube get management kcm -o jsonpath='{range .status.components}{"\n"}{@}{end}' >&2 || true
    exit 1
fi

step "Verifying the installed provider set"
read -ra expected <<< "$KCM_PROVIDERS"
for provider in "${expected[@]}"; do
    kube get management kcm -o jsonpath='{.spec.providers[*].name}' | tr ' ' '\n' | grep -qx "$provider" \
        || die "Provider '$provider' is missing from Management.spec.providers"
    log "✅ $provider"
done

installed_count="$(kube get management kcm -o jsonpath='{.spec.providers[*].name}' | wc -w | tr -d ' ')"
log "Management enables $installed_count provider(s)"

step "Waiting for ClusterTemplates to become valid"
# These stay invalid until a Management exists, so they can only be checked here.
RELEASE_ENV="$WORKDIR/release.env"
if [[ -f "$RELEASE_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$RELEASE_ENV"
    for name in ${CLUSTER_TEMPLATES:-}; do
        wait_for_valid ClusterTemplate "$name" "$NAMESPACE" "$TEMPLATES_TIMEOUT"
    done
else
    warn "$RELEASE_ENV not found -- skipping the ClusterTemplate check"
fi

step "Waiting for the projectsveltos pods"
if kube get namespace projectsveltos >/dev/null 2>&1; then
    NAMESPACE=projectsveltos "$SCRIPTS_DIR/wait_for_deployment.sh"
else
    warn "Namespace 'projectsveltos' does not exist -- skipping"
fi

kube get management kcm
ok "KCM management is up"
