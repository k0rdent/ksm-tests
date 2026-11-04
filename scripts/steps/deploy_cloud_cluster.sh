#!/usr/bin/env bash
set -euo pipefail

# A cluster k0rdent provisions at a provider, handed to the scenarios as the
# child cluster. Follows k0rdent/catalog's deploy_cld.sh: the credential chart,
# the ClusterTemplate names read back from the cluster, and the per-provider
# ClusterDeployment in scripts/config/<mode>-cld.yaml, all copied from there.
#
# A no-op unless TEST_MODE names a provider, so it can sit in the pipeline
# always.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

if ! is_cloud_mode; then
    log "TEST_MODE=$TEST_MODE -- no cluster to provision"
    exit 0
fi

require_cmd kubectl helm
ensure_workdir
time_phase "$(provider_label) cluster create"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

# CI has already run this as its first step, so the credentials are known good
# by now. Kept because a local run comes straight here, and because it is
# cheap next to what follows.
"$SCRIPTS_DIR/steps/check_provider_creds.sh"

step "Installing the $TEST_MODE Credential"
# From the repository root, like everything catalog's: they call each other as
# ./scripts/<name>.sh. See scripts/CATALOG.md.
( cd "$PROJECT_ROOT" && ./scripts/setup_provider_credential.sh )

# The chart install and the secret patches return before the controller has set
# status.ready, and the ClusterDeployment webhook rejects a Credential that is
# not ready -- which ends the run before any provisioning starts. The adopted
# path waits for the same thing; so does this one now.
wait_for_ready Credential "$TEST_MODE-credential" "$NAMESPACE" "$MCS_TIMEOUT" \
    || die "Credential '$TEST_MODE-credential' never became ready"

# The ClusterTemplate names carry a version that moves with every k0rdent
# release, so they are read back from the cluster rather than pinned.
#
# Sourced with errexit and pipefail off, and that is not defensive dressing:
# it resolves the name of every provider's template, we install only the one
# this mode needs, so its greps for the others find nothing and fail. Under
# `set -euo pipefail` that kills the run with no output at all. Catalog never
# sees it because its Management installs every template. The name we actually
# need is checked immediately after, which is the assertion that matters.
set +e +o pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/export_cluster_template_names.sh"
set -e -o pipefail

case "$TEST_MODE" in
    aws)   CLUSTER_TEMPLATE="$CT_AWS_STANDALONE_CP" ;;
    azure) CLUSTER_TEMPLATE="$CT_AZURE_STANDALONE_CP" ;;
    gcp)   CLUSTER_TEMPLATE="$CT_GCP_STANDALONE_CP" ;;
esac
[[ -n "${CLUSTER_TEMPLATE:-}" ]] || die "No $TEST_MODE-standalone-cp ClusterTemplate in '$NAMESPACE'.
KCM_CLUSTER_TEMPLATES='$KCM_CLUSTER_TEMPLATES' -- was it installed and is it valid?"
log "ClusterTemplate: $CLUSTER_TEMPLATE"

CLD_FILE="$CONFIG_DIR/$TEST_MODE-cld.yaml"
[[ -f "$CLD_FILE" ]] || die "No ClusterDeployment template at $CLD_FILE"

MANIFEST="$ENVDIR/$TEST_MODE-cld.rendered.yaml"
# The same substitutions catalog makes, so the files stay copyable from there.
sed -e "s/CLD_NAME/${CLD_NAME}/g" \
    -e "s/AWS_EC2_FAMILY/${AWS_EC2_FAMILY:-FILL}/g" -e "s/AWS_REGION/${AWS_REGION:-FILL}/g" \
    -e "s/AZURE_SUB_ID/${AZURE_SUB_ID:-FILL}/g" -e "s/AZURE_LOCATION/${AZURE_LOCATION:-FILL}/g" \
    -e "s/GCP_PROJECT/${GCP_PROJECT:-FILL}/g" -e "s/GCP_REGION/${GCP_REGION:-FILL}/g" \
    -e "s/CT_AWS_STANDALONE_CP/${CT_AWS_STANDALONE_CP:-}/g" \
    -e "s/CT_AZURE_STANDALONE_CP/${CT_AZURE_STANDALONE_CP:-}/g" \
    -e "s/CT_GCP_STANDALONE_CP/${CT_GCP_STANDALONE_CP:-}/g" \
    "$CLD_FILE" > "$MANIFEST"

# The name and the label, set rather than left to the sed above. Catalog's own
# files do not agree on how the name gets in -- ours all use the CLD_NAME
# placeholder, a copy from there may not -- and a substitution that misses
# leaves a cluster named something nobody waits for or deletes: a 40-minute
# timeout followed by a teardown that removes nothing, with the real cluster
# still running. Setting the field works whatever the file says.
#
# The label is what render_mcs selects on; catalog's own type/group labels are
# for its demos and are left alone.
yq -i ".metadata.name = \"$CLD_NAME\" |
       .metadata.labels.\"$CLD_LABEL_KEY\" = \"$CLD_LABEL_VALUE\"" "$MANIFEST"

step "Creating the ClusterDeployment '$CLD_NAME'"
cat "$MANIFEST"
kube apply -n "$NAMESPACE" -f "$MANIFEST"

step "Waiting for '$CLD_NAME' to be provisioned"
# Minutes, not seconds: a cloud control plane takes its time. The object's own
# row is printed each poll rather than a tick every 30s -- its MESSAGES column
# is the progress ("InfrastructureReady: 0 of 8 completed"), and without it a
# quarter of an hour of silence is indistinguishable from a hang.
if ! wait_for_condition ClusterDeployment "$CLD_NAME" "$NAMESPACE" Ready "$CLUSTER_TIMEOUT" 5 \
     kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --no-headers; then
    { kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" -o yaml
      kcm_errors 20m; } >&2
    die "ClusterDeployment '$CLD_NAME' never became Ready"
fi

step "Fetching the child kubeconfig"
kube get secret "$CLD_NAME-kubeconfig" -n "$NAMESPACE" -o jsonpath='{.data.value}' \
    | base64 -d > "$KUBECONFIG_CLOUD"
chmod 0600 "$KUBECONFIG_CLOUD"
log "$KUBECONFIG_CLOUD"

step "Waiting for the child cluster's own pods"
KUBECONFIG="$KUBECONFIG_CLOUD" NAMESPACE=kube-system "$SCRIPTS_DIR/utils/wait_for_deployment.sh"
if kube_child get namespace projectsveltos >/dev/null 2>&1; then
    KUBECONFIG="$KUBECONFIG_CLOUD" NAMESPACE=projectsveltos "$SCRIPTS_DIR/utils/wait_for_deployment.sh"
fi

step "The $TEST_MODE cluster"
kube_child get nodes -o wide
# Everything, like catalog: what a provisioned cluster brought up on its own is
# the context for anything that goes wrong in the scenarios afterwards.
kube_child get pods -A

# What was provisioned, so remove_k0rdent.sh can take it down before it
# destroys the controllers that know how. Written last: a run that got no
# cluster has nothing for the teardown to chase.
{
    echo "TEST_MODE='$TEST_MODE'"
    echo "CLD_NAME='$CLD_NAME'"
} > "$ENVDIR/cloud.env"

ok "The $TEST_MODE cluster '$CLD_NAME' is ready"
