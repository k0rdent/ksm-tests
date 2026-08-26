#!/bin/bash
set -euo pipefail

# Make the built artifacts reachable from the cluster: images go into the k0s
# node's containerd, template charts into the local OCI registry.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"

require_cmd docker make

[[ -d "$KCM_DIR" ]] || die "KCM source not found at $KCM_DIR. Run ./scripts/build_kcm.sh first."
container_running "$MGMT_CLUSTER_NAME" \
    || die "Management cluster '$MGMT_CLUSTER_NAME' is not running. Run ./scripts/deploy_mgmt_cluster.sh first."
container_running "$REGISTRY_NAME" \
    || die "Registry '$REGISTRY_NAME' is not running. Run ./scripts/deploy_registry.sh first."

step "Importing images into the management cluster"
import_image_into_k0s "$IMG" "$MGMT_CLUSTER_NAME"
import_image_into_k0s "$IMG_TELEMETRY" "$MGMT_CLUSTER_NAME"

step "Pushing template charts to $REGISTRY_REPO"
# helm-push packages every chart under templates/ and skips versions that are
# already in the registry, so re-runs are cheap.
make -C "$KCM_DIR" helm-push REGISTRY_REPO="$REGISTRY_REPO"

ok "Images and charts are available to the cluster"
