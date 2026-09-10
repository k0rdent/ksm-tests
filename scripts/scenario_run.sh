#!/bin/bash
set -euo pipefail

# Run one scenario against ./kcfg_k0rdent: install the ServiceTemplates, deploy
# the services through a MultiClusterService, verify them, remove them again.
#
#   export SCENARIO=01_basic            # required; ./scripts/get_scenarios.sh lists them
#   ./scripts/scenario_run.sh
#
#   SCENARIO_KEEP=true                  # stop before removing, to look around
#   ./scripts/scenario_clean.sh         # remove them afterwards
#
# Needs no KCM: it runs against whatever k0rdent ./kcfg_k0rdent points at,
# whether deploy_k0rdent.sh built it or you did.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

check_scenario
require_cluster
ensure_workdir

START=$SECONDS
trap 'rc=$?; (( rc == 0 )) || { warn "Scenario $SCENARIO failed"; \
      "$SCRIPTS_DIR/collect_logs.sh" || true; }' EXIT

step "Scenario $SCENARIO"

"$SCRIPTS_DIR/install_servicetemplate.sh"
"$SCRIPTS_DIR/deploy_mcs.sh"
# No-op unless the scenario has an upgrade block.
"$SCRIPTS_DIR/upgrade_services.sh"
# No-op unless the scenario declares upgrade.steps.
"$SCRIPTS_DIR/upgrade_chain.sh"

if [[ "${SCENARIO_KEEP:-false}" == "true" ]]; then
    ok "$SCENARIO deployed in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
    log "Services left running. Remove them with ./scripts/scenario_clean.sh"
    exit 0
fi

"$SCRIPTS_DIR/remove_services.sh"

ok "$SCENARIO passed in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
