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
: > "$MANIFEST"

step "Scenario $SCENARIO: rendering $(service_count) ServiceTemplate(s)"

while IFS="$SERVICE_SEP" read -r name chart version repo namespace _dep _wait; do
    [[ -n "$name" ]] || continue
    tmpl="$(template_name_for "$chart" "$version")"
    log "$tmpl  <-  $repo  (namespace $namespace)"

    cat >> "$MANIFEST" <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: $name
  namespace: $NAMESPACE
  labels:
    # KCM runs flux with --watch-label-selector=k0rdent.mirantis.com/managed=true.
    # Without this label source-controller never sees the repository, and the
    # HelmChart fails with a misleading "HelmRepository not found".
    k0rdent.mirantis.com/managed: "true"
spec:
  type: $(repo_type "$repo")
  interval: 10m0s
  url: $repo
---
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ServiceTemplate
metadata:
  name: $tmpl
  namespace: $NAMESPACE
spec:
  helm:
    chartSpec:
      chart: $chart
      version: $version
      interval: 10m0s
      sourceRef:
        kind: HelmRepository
        name: $name
EOF
done < <(services_rows)

step "Applying"
kube apply -f "$MANIFEST"

step "Waiting for the ServiceTemplates to become valid"
while IFS="$SERVICE_SEP" read -r name chart version _repo _ns _dep _wait; do
    [[ -n "$name" ]] || continue
    wait_for_valid ServiceTemplate "$(template_name_for "$chart" "$version")" \
        "$NAMESPACE" "$TEMPLATES_TIMEOUT"
done < <(services_rows)

kube get servicetemplates -n "$NAMESPACE"
ok "All ServiceTemplates are valid"
