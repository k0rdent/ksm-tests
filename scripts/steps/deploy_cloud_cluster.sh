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

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

# CI has already run this as its first step, so the credentials are known good
# by now. Kept because a local run comes straight here, and because it is
# cheap next to what follows.
"$SCRIPTS_DIR/steps/check_provider_creds.sh"

step "Installing the $TEST_MODE Credential"
"$SCRIPTS_DIR/catalog/setup_provider_credential.sh"

# The ClusterTemplate names carry a version that moves with every k0rdent
# release, so they are read back from the cluster rather than pinned.
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/catalog/export_cluster_template_names.sh"

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

# The label the MultiClusterService selects on. Catalog's files carry
# type/group labels for its own demos; ours has to be the one render_mcs asks
# for, and adding it here keeps their file copyable unedited.
yq -i ".metadata.labels.\"$ADOPTED_LABEL_KEY\" = \"$ADOPTED_LABEL_VALUE\"" "$MANIFEST"

step "Creating the ClusterDeployment '$CLD_NAME'"
cat "$MANIFEST"
kube apply -n "$NAMESPACE" -f "$MANIFEST"

step "Waiting for '$CLD_NAME' to be provisioned"
# Minutes, not seconds: a cloud control plane takes its time.
if ! wait_for_condition ClusterDeployment "$CLD_NAME" "$NAMESPACE" Ready "$CLUSTER_TIMEOUT"; then
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

kube_child get nodes
ok "The $TEST_MODE cluster '$CLD_NAME' is ready"
