#!/bin/bash
set -euo pipefail

# Create a HelmRepository and ServiceTemplate for every service in
# $SERVICES_FILE, and wait for KCM to validate them -- which means it pulled
# each chart from its upstream repository.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl
require_yq

check_scenario

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

MANIFEST="$WORKDIR/service-templates.rendered.yaml"

step "Scenario $SCENARIO: rendering ServiceTemplates"
render_templates "$MANIFEST" initial
while IFS="$SERVICE_SEP" read -r name chart version repo namespace _dep _wait; do
    [[ -n "$name" ]] || continue
    log "$(template_name_for "$chart" "$version")  <-  $repo  (namespace $namespace)"
done < <(all_services_rows)

step "Applying"
kube apply -f "$MANIFEST"

step "Waiting for the ServiceTemplates to become valid"
# Every version, not just the declared one: a chain scenario upgrades to
# versions rendered above, and starting that before they are valid is a race.
while IFS="$SERVICE_SEP" read -r name chart version _repo _ns _dep _wait; do
    [[ -n "$name" ]] || continue
    for v in $({ echo "$version"; all_versions_for "$name"; } | awk 'NF && !seen[$0]++'); do
        wait_for_valid ServiceTemplate "$(template_name_for "$chart" "$v")" \
            "$NAMESPACE" "$TEMPLATES_TIMEOUT"
    done
done < <(all_services_rows)

if has_template_chain; then
    step "Creating ServiceTemplateChain '$(chain_name)'"
    CHAIN="$WORKDIR/service-template-chain.rendered.yaml"
    render_chain "$CHAIN"
    cat "$CHAIN"
    kube apply -f "$CHAIN"
fi

kube get servicetemplates -n "$NAMESPACE"
ok "All ServiceTemplates are valid"
