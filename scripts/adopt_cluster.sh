#!/bin/bash
set -euo pipefail

# Hand the adopted cluster's kubeconfig to KCM: Secret, Credential, then a
# ClusterDeployment on the adopted-cluster template. Nothing is provisioned --
# the chart only registers a SveltosCluster -- so this is quick.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst
"$SCRIPTS_DIR/check_test_mode.sh"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

INTERNAL_KUBECONFIG="$WORKDIR/adopted-internal.kubeconfig"
[[ -f "$INTERNAL_KUBECONFIG" ]] \
    || die "No $INTERNAL_KUBECONFIG. Run ./scripts/deploy_adopted_cluster.sh first."

# The template name comes from the chart in the checkout, so a chart bump does
# not leave a stale version here.
CHART_DIR="$KCM_DIR/templates/cluster/adopted-cluster"
[[ -d "$CHART_DIR" ]] || die "Cluster template chart not found at $CHART_DIR"
CLD_TEMPLATE="$(template_name "$CHART_DIR")"

ADOPTED_SECRET_NAME="${ADOPTED_SECRET_NAME:-adopted-kubeconf-$CLUSTER_NAME_SUFFIX}"
ADOPTED_CREDENTIAL_NAME="${ADOPTED_CREDENTIAL_NAME:-adopted-cred-$CLUSTER_NAME_SUFFIX}"
# The internal address, not the host one: KCM talks to the cluster from inside
# the docker network.
ADOPTED_KUBECONFIG_B64="$(openssl base64 -A < "$INTERNAL_KUBECONFIG")"
export CLD_TEMPLATE ADOPTED_SECRET_NAME ADOPTED_CREDENTIAL_NAME ADOPTED_KUBECONFIG_B64

step "Applying the kubeconfig Secret and Credential"
envsubst < "$CONFIG_DIR/adopted-credential.yaml" | kube apply -f -
log "secret: $ADOPTED_SECRET_NAME, credential: $ADOPTED_CREDENTIAL_NAME"

step "Creating ClusterDeployment '$CLD_NAME' from template '$CLD_TEMPLATE'"
MANIFEST="$WORKDIR/cld.rendered.yaml"
envsubst < "$CONFIG_DIR/adopted-cld.yaml" > "$MANIFEST"
cat "$MANIFEST"

for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        log "DRY-RUN: ClusterDeployment not created"
        exit 0
    fi
done

kube apply -f "$MANIFEST"

step "Waiting for ClusterDeployment '$CLD_NAME' to become Ready"
if ! wait_for_condition ClusterDeployment "$CLD_NAME" "$NAMESPACE" Ready "$CLD_TIMEOUT" 10; then
    { kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" -o yaml
      kube get sveltoscluster -A -o wide
      kcm_errors 10m; } >&2 2>/dev/null || true
    die "ClusterDeployment '$CLD_NAME' never became Ready"
fi

# The SveltosCluster is what KSM actually deploys through, so a Ready
# ClusterDeployment with an unhealthy SveltosCluster would be a false positive.
step "Checking the SveltosCluster is connected"
elapsed=0
while (( elapsed < CLD_TIMEOUT )); do
    ready="$(kube get sveltoscluster -n "$NAMESPACE" -o jsonpath="{.items[?(@.metadata.name==\"$CLD_NAME\")].status.ready}" 2>/dev/null || true)"
    [[ "$ready" == "true" ]] && break
    (( elapsed % 30 == 0 )) && log "⏳ SveltosCluster '$CLD_NAME' ready='${ready:-<none>}' (${elapsed}s)"
    sleep 5
    elapsed=$(( elapsed + 5 ))
done
[[ "$ready" == "true" ]] \
    || { kube get sveltoscluster -A -o yaml >&2 || true
         die "SveltosCluster '$CLD_NAME' never reported ready"; }

kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE"
kube get sveltoscluster -n "$NAMESPACE"
ok "Cluster adopted and connected"
