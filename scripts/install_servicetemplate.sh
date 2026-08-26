#!/bin/bash
set -euo pipefail

# Install the ServiceTemplate for the service under test and wait for KCM to
# validate it (which means it pulled the chart from the upstream repo).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

SERVICE_TEMPLATE_NAME="$(service_template_name)"
export SERVICE_TEMPLATE_NAME

step "Installing ServiceTemplate '$SERVICE_TEMPLATE_NAME' ($SERVICE_HELM_REPO)"
MANIFEST="$WORKDIR/service-template.rendered.yaml"
envsubst < "$CONFIG_DIR/service-template.yaml" > "$MANIFEST"
kube apply -f "$MANIFEST"

wait_for_valid ServiceTemplate "$SERVICE_TEMPLATE_NAME" "$NAMESPACE" "$TEMPLATES_TIMEOUT"

kube get servicetemplate "$SERVICE_TEMPLATE_NAME" -n "$NAMESPACE"
ok "ServiceTemplate '$SERVICE_TEMPLATE_NAME' is valid"
