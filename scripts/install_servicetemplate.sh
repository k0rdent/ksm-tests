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

step "Scenario $SCENARIO: rendering $(all_services_rows | wc -l | tr -d ' ') ServiceTemplate(s)"
render_templates "$MANIFEST" initial
while IFS="$SERVICE_SEP" read -r name chart version repo namespace _dep _wait; do
    [[ -n "$name" ]] || continue
    log "$(template_name_for "$chart" "$version")  <-  $repo  (namespace $namespace)"
done < <(all_services_rows)

step "Applying"
kube apply -f "$MANIFEST"

step "Waiting for the ServiceTemplates to become valid"
while IFS="$SERVICE_SEP" read -r name chart version _repo _ns _dep _wait; do
    [[ -n "$name" ]] || continue
    wait_for_valid ServiceTemplate "$(template_name_for "$chart" "$version")" \
        "$NAMESPACE" "$TEMPLATES_TIMEOUT"
done < <(all_services_rows)

kube get servicetemplates -n "$NAMESPACE"
ok "All ServiceTemplates are valid"
