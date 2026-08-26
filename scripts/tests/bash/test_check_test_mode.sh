#!/bin/bash
# Tests for scripts/check_test_mode.sh
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

TEST_MODE=docker bash "$SCRIPTS_DIR/check_test_mode.sh" >/dev/null 2>&1
assert_eq "'docker' is accepted (exit 0)" 0 "$?"

out=$(TEST_MODE=bogus bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "'bogus' is rejected (exit 1)" 1 "$?"
assert_contains "prints invalid-mode error" "$out" "Invalid TEST_MODE='bogus'"
assert_contains "lists allowed values" "$out" "docker"

out=$(TEST_MODE="" bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "empty TEST_MODE is rejected (exit 1)" 1 "$?"

# A substring of an allowed mode must not sneak through.
out=$(TEST_MODE=dock bash "$SCRIPTS_DIR/check_test_mode.sh" 2>&1)
assert_eq "substring 'dock' is rejected" 1 "$?"

finish
