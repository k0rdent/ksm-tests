#!/usr/bin/env bash
set -euo pipefail

# Run one scenario against ./kcfg_k0rdent: install the ServiceTemplates, deploy
# the services through a MultiClusterService, verify them, remove them again.
#
#   export SCENARIO=101_basic            # required; ./scripts/scenarios.sh lists them
#   ./scripts/run_scenario.sh
#
#   SCENARIO_KEEP=true                  # stop before removing, to look around
#   ./scripts/clean_scenario.sh         # remove them afterwards
#
# Needs no KCM: it runs against whatever k0rdent ./kcfg_k0rdent points at,
# whether deploy_k0rdent.sh built it or you did.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

check_scenario
require_yq
require_cluster
ensure_workdir

START=$SECONDS
trap 'rc=$?; (( rc == 0 )) || { warn "Scenario $SCENARIO failed"; \
      "$SCRIPTS_DIR/steps/collect_logs.sh" || true; }' EXIT

step "Scenario $SCENARIO"

"$SCRIPTS_DIR/steps/install_servicetemplate.sh"
"$SCRIPTS_DIR/steps/deploy_mcs.sh"
# No-op unless the scenario has an upgrade block.
"$SCRIPTS_DIR/steps/upgrade_services.sh"
# No-op unless the scenario declares upgrade.steps.
"$SCRIPTS_DIR/steps/upgrade_chain.sh"

if [[ "${SCENARIO_KEEP:-false}" == "true" ]]; then
    ok "$SCENARIO deployed in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
    log "Services left running. Remove them with ./scripts/clean_scenario.sh"
    exit 0
fi

"$SCRIPTS_DIR/steps/remove_services.sh"

# Install a second time over what the removal left behind. Helm never deletes a
# chart's CRDs on uninstall, so the second install meets them, and the
# ServiceTemplates have to be put back because the removal takes those too.
if has_redeploy; then
    step "Scenario $SCENARIO: installing again over what the removal left behind"
    "$SCRIPTS_DIR/steps/install_servicetemplate.sh"
    "$SCRIPTS_DIR/steps/deploy_mcs.sh"
    # Scenarios run one after another on the same management cluster, so this
    # one has to leave it as empty as it found it.
    "$SCRIPTS_DIR/steps/remove_services.sh"
fi

ok "$SCENARIO passed in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
