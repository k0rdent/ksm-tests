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
    out="$(mk "help-$target")"
    assert_contains "help-$target explains itself" "$out" "Vars:"
done < <(grep -B1 -hE '^[a-zA-Z0-9_-]+:.*?## ' "$REPO_ROOT/Makefile" \
    | grep -A1 '^#:' | grep -E '^[a-zA-Z0-9_-]+:' | cut -d: -f1)

assert_contains "env-down names RUN_ID" "$(mk help-env-down)" "RUN_ID"
assert_contains "an unknown target says so" "$(mk help-nope)" "No target nope"

finish
