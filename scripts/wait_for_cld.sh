#!/bin/bash
set -euo pipefail

# Wait for $CLD_NAME to report Ready.
#
# Provisioning goes through CAPI -> CAPD (node containers) -> k0smotron
# (hosted control plane), so this is the slowest step in the run.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl

export KUBECONFIG="$KUBECONFIG_MGMT"

step "Waiting for ClusterDeployment '$CLD_NAME' to become Ready"

if ! wait_for_condition ClusterDeployment "$CLD_NAME" "$NAMESPACE" Ready "$CLD_TIMEOUT" 10; then
    warn "CAPI resources at the time of failure:"
    {
        kube get clusters,machines,machinedeployments -A -o wide
        kube get devclusters,devmachines -A -o wide
        kube get k0smotroncontrolplanes -A -o wide
        docker ps --filter "name=$CLD_NAME" --format 'table {{.Names}}\t{{.Status}}'
    } >&2 2>/dev/null || true
    exit 1
fi

kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE"
ok "ClusterDeployment '$CLD_NAME' is Ready"
