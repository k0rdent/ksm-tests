#!/bin/bash
# `make help` lists every target, and `make help-<target>` explains one.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

mk() { make --no-print-directory -C "$REPO_ROOT" "$@" 2>&1; }

listed="$(mk help)"

# The pattern used to exclude digits, which hid the e2e targets -- the very
# command the help text tells you to run.
while read -r target; do
    [[ -n "$target" ]] || continue
    assert_contains "help lists $target" "$listed" "$target"
done < <(grep -hE '^[a-zA-Z0-9_-]+:.*?## ' "$REPO_ROOT/Makefile" | cut -d: -f1)

# Every target carrying detail must be reachable, and say which vars it takes.
while read -r target; do
    [[ -n "$target" ]] || continue
    out="$(mk "$target-help")"
    assert_contains "$target-help explains itself" "$out" "Vars:"
done < <(grep -B1 -hE '^[a-zA-Z0-9_-]+:.*?## ' "$REPO_ROOT/Makefile" \
    | grep -A1 '^#:' | grep -E '^[a-zA-Z0-9_-]+:' | cut -d: -f1)

assert_contains "env-down names RUN_ID" "$(mk env-down-help)" "RUN_ID"
assert_contains "an unknown target says so" "$(mk nope-help)" "No target nope"

# `make <target> help` is a list of two goals to make, so without the guard it
# builds the cluster and prints the help afterwards. Assert on the dry run:
# whatever else changes, the help form must never reach a script.
for order in "env-up help" "help env-up"; do
    # shellcheck disable=SC2086  # two goals, deliberately split
    out="$(mk -n $order)"
    assert_not_contains "'make $order' runs nothing" "$out" "e2e_test.sh"
    assert_contains "'make $order' explains env-up" "$out" "env-up-help"
done
assert_contains "make env-up alone still builds" "$(mk -n env-up)" "e2e_test.sh"
assert_contains "make help alone still lists targets" "$(mk help)" "Show this help"

finish
