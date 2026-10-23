#!/usr/bin/env bash
# CI runs one step per script so a failure is visible in the step list, while a
# local run goes through deploy_k0rdent.sh and run_scenario.sh. That is the
# same pipeline written twice, so assert the two agree -- a script added to one
# and forgotten in the other is exactly the drift this catches.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/e2e-scenario.yml"

# Teardown and diagnostics are the job's own business, not part of the
# pipeline: CI runs them on failure and cleanup, the entry points in a trap.
NOT_PIPELINE='collect_logs|remove_k0rdent|remove_adopted_cluster|remove_cloud_cluster'

strip() { sed -E 's#.*/##' | grep -vE "^($NOT_PIPELINE)\.sh$"; }

# Only real invocations: a `run:` key in the workflow, and a command at the
# start of a line in the entry points. Anchored so the usage comments at the
# top of each script -- which name the script itself -- are not counted.
ci="$(grep -oE '^ +run: \./scripts/steps/[a-z_0-9]+\.sh$' "$WORKFLOW" | strip)"
# shellcheck disable=SC2016 # $SCRIPTS_DIR is the literal text being matched
local_run="$(grep -hoE '^ *"\$SCRIPTS_DIR/steps/[a-z_0-9]+\.sh"' \
    "$SCRIPTS_DIR/deploy_k0rdent.sh" "$SCRIPTS_DIR/run_scenario.sh" \
    | tr -d '"' | strip)"

# e2e-scenario.yml runs self and adopted, never a provisioned cluster, so
# neither the credential check nor the provisioning is part of its pipeline.
# The entry point carries both because it serves every mode -- and only this
# side is filtered: the serial workflow below does run them, and is checked
# against the unfiltered list.
CLOUD_ONLY='check_provider_creds|deploy_cloud_cluster'
assert_eq "CI runs the same scripts, in the same order, as the entry points" \
    "$(grep -vE "^($CLOUD_ONLY)\.sh$" <<< "$local_run")" "$ci"

# A guard on the guard: if the extraction ever matches nothing, the comparison
# above passes trivially and stops protecting anything.
assert_not_eq "the workflow extraction found something" "" "$ci"
assert_contains "and it really is the pipeline" "$ci" "wait_for_management.sh"

# e2e-serial.yml builds the same environment and then runs the scenarios one
# step at a time, so only the build half is comparable -- and against
# deploy_k0rdent.sh alone.
SERIAL="$REPO_ROOT/.github/workflows/e2e-serial.yml"
serial_ci="$(grep -oE '^ +run: \./scripts/steps/[a-z_0-9]+\.sh$' "$SERIAL" | strip)"
# shellcheck disable=SC2016 # $SCRIPTS_DIR is the literal text being matched
build_local="$(grep -hoE '^ *"\$SCRIPTS_DIR/steps/[a-z_0-9]+\.sh"' \
    "$SCRIPTS_DIR/deploy_k0rdent.sh" | tr -d '"' | strip)"

assert_eq "the serial workflow builds the environment like deploy_k0rdent.sh" \
    "$build_local" "$serial_ci"
assert_contains "and it really is the build" "$serial_ci" "wait_for_management.sh"
assert_contains "the serial workflow runs the scenarios through run_scenarios.sh" \
    "$(cat "$SERIAL")" "run_scenarios.sh"

# One step per scenario, written out because Actions has no per-step matrix. A
# scenario added to test_scenarios/ and not here would be skipped in every
# serial run, and a skipped step reads as coverage nobody is missing.
serial_steps="$(grep -oE '^ +run: SCENARIOS=[a-z_0-9]+ ' "$SERIAL" \
    | sed -E 's/.*SCENARIOS=//; s/ $//' | sort)"
all_scenarios=""
for f in "$REPO_ROOT"/test_scenarios/*.yaml; do all_scenarios+="$(basename "$f" .yaml)"$'\n'; done
assert_eq "the serial workflow has a step for every scenario" \
    "$(sort <<< "${all_scenarios%$'\n'}" | tr '\n' ' ')" "$(tr '\n' ' ' <<< "$serial_steps")"

# Each of those steps has to be switchable, or the 'scenarios' input stops
# selecting anything and every run is the full set.
assert_eq "and each one is conditional on the input" \
    "$(wc -l <<< "$serial_steps")" \
    "$(grep -cE "^ +if: contains\(env\.SCENARIO_LIST, ' [a-z_0-9]+ '\)$" "$SERIAL")"

finish
