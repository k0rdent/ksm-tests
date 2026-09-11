#!/bin/bash
set -euo pipefail

# Build a k0rdent test cluster: one k0s node in Docker with KCM installed.
# Around 5 minutes. Nothing is provisioned -- the scenarios use KCM's
# selfManagement, so the services land in this same cluster.
#
#   export KCM=1.12.0-rc.3            # required: a published chart version
#   ./scripts/deploy_k0rdent.sh
#
#   export KCM=main KCM_MODE=source   # or build a branch, tag or commit
#   ./scripts/deploy_k0rdent.sh
#
# Writes the kubeconfig to ./kcfg_k0rdent_$KCM and points ./kcfg_k0rdent at it,
# which is what the scenario scripts read.
#
# Other knobs: OCI_URL (chart registry, e.g. .../staging), SRC_URL (the git
# repository to build in source mode), KCM_SRC_DIR (an existing checkout).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_kcm
ensure_workdir

START=$SECONDS
trap 'rc=$?; (( rc == 0 )) || { warn "Failed after $(( (SECONDS - START) / 60 ))m"; \
      "$SCRIPTS_DIR/steps/collect_logs.sh" || true; }' EXIT

log "KCM=$KCM ($KCM_MODE), cluster $MGMT_CLUSTER_NAME"

"$SCRIPTS_DIR/steps/deps.sh"
"$SCRIPTS_DIR/steps/prepare_kcm.sh"

# The local registry only exists to serve charts we built ourselves.
if [[ "$KCM_MODE" == "source" ]]; then
    "$SCRIPTS_DIR/steps/deploy_registry.sh"
fi

"$SCRIPTS_DIR/steps/deploy_mgmt_cluster.sh"

if [[ "$KCM_MODE" == "source" ]]; then
    "$SCRIPTS_DIR/steps/push_kcm_artifacts.sh"
fi

"$SCRIPTS_DIR/steps/deploy_kcm.sh"
"$SCRIPTS_DIR/steps/apply_release.sh"
"$SCRIPTS_DIR/steps/wait_for_templates.sh"
"$SCRIPTS_DIR/steps/apply_management.sh"
"$SCRIPTS_DIR/steps/wait_for_management.sh"

ok "k0rdent $KCM is up in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
log "export KUBECONFIG=${KUBECONFIG_MGMT#"$PROJECT_ROOT"/}"
log "Run a scenario: SCENARIO=01_basic ./scripts/scenario_run.sh"
