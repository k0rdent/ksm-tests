#!/bin/bash
# Tests for scripts/check_test_mode.sh
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

TEST_MODE=self bash "$SCRIPTS_DIR/check_test_mode.sh" >/dev/null 2>&1
assert_eq "'self' is accepted (exit 0)" 0 "$?"

out=$(TEST_MODE=bogus bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "'bogus' is rejected (exit 1)" 1 "$?"
assert_contains "prints invalid-mode error" "$out" "Invalid TEST_MODE='bogus'"
assert_contains "lists allowed values" "$out" "self"

out=$(TEST_MODE="" bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "empty TEST_MODE is rejected (exit 1)" 1 "$?"

# A substring of an allowed mode must not sneak through.
out=$(TEST_MODE=sel bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "substring 'sel' is rejected" 1 "$?"
# The mode that used to run a second cluster is gone, not merely undocumented.
out=$(TEST_MODE=adopted bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "'adopted' is rejected now" 1 "$?"

finish
