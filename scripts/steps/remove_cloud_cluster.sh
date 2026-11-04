#!/usr/bin/env bash
# Remove the provisioned cluster. Best-effort and never fatal on its own, like
# remove_k0rdent.sh: this runs from CI's always() and from a trap, and a half
# built environment must not stop it. What it must not do is return before the
# provider has actually let go -- that is a running bill.
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

if ! is_cloud_mode; then
    log "TEST_MODE=$TEST_MODE -- no provisioned cluster to remove"
    exit 0
fi

time_phase "$(provider_label) cluster remove"

if [[ ! -f "$KUBECONFIG_MGMT" ]]; then
    warn "No management kubeconfig at $KUBECONFIG_MGMT -- cannot remove '$CLD_NAME'"
    warn "Check the provider for leftovers:"
    warn "  TEST_MODE=$TEST_MODE ./scripts/list_cld_resources_$TEST_MODE.sh"
    exit 0
fi
export KUBECONFIG="$KUBECONFIG_MGMT"

step "Removing the $TEST_MODE cluster '$CLD_NAME'"

# `|| rc=$?`, not a bare call: this script does not run under `set -e`, but the
# shape has to be the one that survives if it ever does.
rc=0
resource_exists ClusterDeployment "$CLD_NAME" "$NAMESPACE" || rc=$?
case $rc in
    1)
        log "No ClusterDeployment '$CLD_NAME' -- nothing was provisioned"
        rm -f "$KUBECONFIG_CLOUD"
        ok "Nothing to remove"
        exit 0
        ;;
    2)
        # Not an absence: the question went unanswered. Treating it as "nothing
        # was provisioned" is how a teardown reports success over a cluster that
        # is still billing, so this is the one place that must not guess.
        warn "Cannot reach the management API to check for '$CLD_NAME'."
        warn "Not assuming it is gone. Check the provider for leftovers:"
        warn "  TEST_MODE=$TEST_MODE ./scripts/list_cld_resources_$TEST_MODE.sh"
        exit 1
        ;;
esac

step "What is there before the delete"
kube get clusterdeployment -n "$NAMESPACE"

step "Deleting the ClusterDeployment"
# --wait=false and then watch: the delete call blocks for as long as the
# finalizers take, and a blocked call reports nothing meanwhile.
kube delete clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --wait=false

step "Waiting for the provider to release it"
log "This is where the instances, volumes and network actually go."
if ! wait_for_absence ClusterDeployment "$CLD_NAME" "$NAMESPACE" "$CLUSTER_TIMEOUT" 10 \
     kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --no-headers; then
    { kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" -o yaml
      kcm_errors 20m; } >&2
    warn "'$CLD_NAME' did not go away. Resources are most likely still running:"
    warn "  TEST_MODE=$TEST_MODE ./scripts/list_cld_resources_$TEST_MODE.sh"
    # Loud and non-zero: this is the one failure in a teardown that must
    # not be shrugged off, because it costs money until someone looks.
    exit 1
fi

step "What is left"
kube get clusterdeployment -n "$NAMESPACE"
rm -f "$KUBECONFIG_CLOUD"
# The note that told remove_k0rdent.sh there was something at a provider. Only
# now, with the cluster actually gone -- while it is there, that file is what
# stops the management cluster being destroyed on top of it.
rm -f "$ENVDIR/cloud.env"
ok "The $TEST_MODE cluster is gone"
