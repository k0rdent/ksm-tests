#!/bin/bash
# CI runs one step per script so a failure is visible in the step list, while a
# local run goes through deploy_k0rdent.sh and scenario_run.sh. That is the
# same pipeline written twice, so assert the two agree -- a script added to one
# and forgotten in the other is exactly the drift this catches.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/e2e-scenario.yml"

# Teardown and diagnostics are the job's own business, not part of the
# pipeline: CI runs them on failure and cleanup, the entry points in a trap.
NOT_PIPELINE='collect_logs|remove_k0rdent'

strip() { sed -E 's#.*/##' | grep -vE "^($NOT_PIPELINE)\.sh$"; }

# Only real invocations: a `run:` key in the workflow, and a command at the
# start of a line in the entry points. Anchored so the usage comments at the
# top of each script -- which name the script itself -- are not counted.
ci="$(grep -oE '^ +run: \./scripts/steps/[a-z_0-9]+\.sh$' "$WORKFLOW" | strip)"
# shellcheck disable=SC2016 # $SCRIPTS_DIR is the literal text being matched
local_run="$(grep -hoE '^ *"\$SCRIPTS_DIR/steps/[a-z_0-9]+\.sh"' \
    "$SCRIPTS_DIR/deploy_k0rdent.sh" "$SCRIPTS_DIR/scenario_run.sh" \
    | tr -d '"' | strip)"

assert_eq "CI runs the same scripts, in the same order, as the entry points" \
    "$local_run" "$ci"

# A guard on the guard: if the extraction ever matches nothing, the comparison
# above passes trivially and stops protecting anything.
assert_not_eq "the workflow extraction found something" "" "$ci"
assert_contains "and it really is the pipeline" "$ci" "wait_for_management.sh"

finish
