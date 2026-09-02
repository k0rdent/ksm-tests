#!/bin/bash
set -euo pipefail

# End-to-end run, in three phases so the expensive part can be reused.
#
#   ./scripts/e2e_test.sh                  # everything, then tear down
#   ./scripts/e2e_test.sh --keep           # everything, leave it running
#   ./scripts/e2e_test.sh --env-up         # cluster + KCM + child cluster only
#   ./scripts/e2e_test.sh --scenario-only  # services only, on an existing env
#   ./scripts/e2e_test.sh --scenario-only --keep-resources  # deploy only, skip remove
#   ./scripts/e2e_test.sh --scenario-only --clean-only      # remove only
#   ./scripts/e2e_test.sh --env-down       # tear down
#
# Building the environment takes most of the wall clock, so --env-up once
# followed by several --scenario-only runs is the fast way to work through
# scenarios locally. CI does not do this: there every combination gets its own
# runner, which is what keeps the scenarios independent.
#
#   SCENARIO=02dep01_valid KCM=rel-1-11-0 ./scripts/e2e_test.sh

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KEEP=false
DO_ENV=true
DO_SCENARIO=true
DO_DOWN=false
KEEP_RESOURCES=false
CLEAN_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --keep)          KEEP=true ;;
        --env-up)        DO_SCENARIO=false; KEEP=true ;;
        --scenario-only) DO_ENV=false; KEEP=true ;;
        --keep-resources) KEEP_RESOURCES=true ;;
        --clean-only)    CLEAN_ONLY=true ;;
        --env-down)      DO_ENV=false; DO_SCENARIO=false; DO_DOWN=true ;;
        *) die "Unknown argument: $arg (--keep, --env-up, --scenario-only, --keep-resources, --clean-only, --env-down)" ;;
    esac
done

check_scenario

if [[ "$DO_DOWN" == "true" ]]; then
    "$SCRIPTS_DIR/cleanup.sh"
    exit 0
fi

START=$SECONDS
FAILED=false

on_exit() {
    local rc=$?
    if (( rc != 0 )); then
        FAILED=true
        warn "Run failed (exit $rc) after $(( (SECONDS - START) / 60 ))m"
        "$SCRIPTS_DIR/collect_logs.sh" || true
    fi
    if [[ "$KEEP" == "true" ]]; then
        log "Leaving the environment up. Tear down with ./scripts/cleanup.sh"
    else
        "$SCRIPTS_DIR/cleanup.sh" || true
    fi
    if [[ "$FAILED" == "false" ]]; then
        ok "Done in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
    fi
    exit "$rc"
}
trap on_exit EXIT

log "KCM_MODE=$KCM_MODE${KCM:+ (KCM=$KCM)}, SCENARIO=$SCENARIO${RUN_ID:+, RUN_ID=$RUN_ID}"

if [[ "$DO_ENV" == "true" ]]; then
    "$SCRIPTS_DIR/check_test_mode.sh"
    "$SCRIPTS_DIR/deps.sh"
    "$SCRIPTS_DIR/prepare_kcm.sh"

    # The local registry only exists to serve charts we built ourselves.
    if [[ "$KCM_MODE" == "source" ]]; then
        "$SCRIPTS_DIR/deploy_registry.sh"
    fi

    "$SCRIPTS_DIR/deploy_mgmt_cluster.sh"

    if [[ "$KCM_MODE" == "source" ]]; then
        "$SCRIPTS_DIR/push_kcm_artifacts.sh"
    fi

    "$SCRIPTS_DIR/deploy_kcm.sh"
    "$SCRIPTS_DIR/apply_release.sh"
    "$SCRIPTS_DIR/wait_for_templates.sh"
    "$SCRIPTS_DIR/apply_management.sh"
    "$SCRIPTS_DIR/wait_for_management.sh"
    "$SCRIPTS_DIR/deploy_adopted_cluster.sh"
    "$SCRIPTS_DIR/adopt_cluster.sh"
fi

if [[ "$DO_SCENARIO" == "true" && "${SKIP_SERVICE_TEST:-false}" != "true" ]]; then
    # Same step names as CI: knownFailures entries reference them.
    step_run() { "$SCRIPTS_DIR/ci_step.sh" "$1" "$2"; }
    if [[ "$CLEAN_ONLY" != "true" ]]; then
        step_run "Install ServiceTemplates" "$SCRIPTS_DIR/install_servicetemplate.sh"
        step_run "Deploy services via MultiClusterService" "$SCRIPTS_DIR/deploy_mcs.sh"
        # No-op unless the scenario has an upgrade block.
        step_run "Upgrade services" "$SCRIPTS_DIR/upgrade_services.sh"
        # No-op unless the scenario declares upgrade.steps.
        step_run "Upgrade along the chain" "$SCRIPTS_DIR/upgrade_chain.sh"
    fi
    if [[ "$KEEP_RESOURCES" != "true" ]]; then
        step_run "Remove services" "$SCRIPTS_DIR/remove_services.sh"
    fi
fi

# Only a full run owns the environment, so only it tears the cluster down.
# --env-up leaves it for the --scenario-only runs that follow.
if [[ "$DO_ENV" == "true" && "$DO_SCENARIO" == "true" ]]; then
    "$SCRIPTS_DIR/remove_cld.sh"
    "$SCRIPTS_DIR/remove_kcm.sh"
fi
