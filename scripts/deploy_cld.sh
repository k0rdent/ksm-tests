#!/bin/bash
set -euo pipefail

# Create the ClusterDeployment under test and wait for it to come up.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst
"$SCRIPTS_DIR/check_test_mode.sh"

export KUBECONFIG="$KUBECONFIG_MGMT"
ensure_workdir

# Resolve the template name from the chart in the source tree rather than
# hardcoding a version that goes stale on the next chart bump.
CHART_DIR="$KCM_DIR/templates/cluster/docker-hosted-cp"
[[ -d "$CHART_DIR" ]] || die "Cluster template chart not found at $CHART_DIR"
CLD_TEMPLATE="$(template_name "$CHART_DIR")"
export CLD_TEMPLATE

step "Applying the CAPD stub credential"
envsubst < "$CONFIG_DIR/docker-credential.yaml" | kube apply -f -

step "Creating ClusterDeployment '$CLD_NAME' from template '$CLD_TEMPLATE'"
MANIFEST="$WORKDIR/cld.rendered.yaml"
envsubst < "$CONFIG_DIR/docker-cld.yaml" > "$MANIFEST"
cat "$MANIFEST"

for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        log "DRY-RUN: ClusterDeployment not created"
        exit 0
    fi
done

kube apply -f "$MANIFEST"

"$SCRIPTS_DIR/wait_for_cld.sh"
