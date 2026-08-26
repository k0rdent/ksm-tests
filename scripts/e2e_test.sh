#!/bin/bash
set -euo pipefail

# Full end-to-end run. CI executes the same scripts step by step.
#
#   ./scripts/e2e_test.sh            # run and clean up
#   ./scripts/e2e_test.sh --keep     # leave the environment running

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KEEP=false
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        *) die "Unknown argument: $arg (supported: --keep)" ;;
    esac
done

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
        log "--keep: leaving the environment up. Tear down with ./scripts/cleanup.sh"
    else
        "$SCRIPTS_DIR/cleanup.sh" || true
    fi
    if [[ "$FAILED" == "false" ]]; then
        ok "e2e passed in $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s"
    fi
    exit "$rc"
}
trap on_exit EXIT

"$SCRIPTS_DIR/check_test_mode.sh"
"$SCRIPTS_DIR/deps.sh"
"$SCRIPTS_DIR/build_kcm.sh"
"$SCRIPTS_DIR/deploy_registry.sh"
"$SCRIPTS_DIR/deploy_mgmt_cluster.sh"
"$SCRIPTS_DIR/install_openebs.sh"
"$SCRIPTS_DIR/push_kcm_artifacts.sh"
"$SCRIPTS_DIR/deploy_kcm.sh"
"$SCRIPTS_DIR/apply_release.sh"
"$SCRIPTS_DIR/wait_for_templates.sh"
"$SCRIPTS_DIR/apply_management.sh"
"$SCRIPTS_DIR/wait_for_management.sh"
"$SCRIPTS_DIR/deploy_cld.sh"
"$SCRIPTS_DIR/check_child_cluster.sh"
"$SCRIPTS_DIR/remove_cld.sh"
