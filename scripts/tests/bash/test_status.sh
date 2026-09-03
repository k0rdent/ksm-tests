#!/bin/bash
# status.sh reports what is built, independent of the current selection.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_mock_bin

# Mock docker: one management container, no adopted one.
write_mock docker <<'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        name=^kcm-mgmt*) echo -e "kcm-mgmt-demo\tUp 3 minutes"; exit 0 ;;
        name=^adopted*)  exit 0 ;;
    esac
done
EOF

# A workdir for that environment, plus one the containers have outlived.
work="$REPO_ROOT/.work-demo"
mkdir -p "$work" "$REPO_ROOT/.work-ghost"
cat > "$work/kcm-build.env" <<'EOF'
KCM_COMMIT='b2ae8b31'
KCM_COMMIT_DATE='Mon 8.6.2026'
KCM_CHART_VERSION='1.10.0'
KCM_MODE='release'
KCM_VARIANT='rel-1-10-0'
EOF

out="$(KCM=rel-1-11-0 RUN_ID=something-else bash "$SCRIPTS_DIR/status.sh" 2>&1)"
assert_contains "lists the built environment" "$out" "demo"
assert_contains "reports the mgmt container" "$out" "Up 3 minutes"
assert_contains "reads the chart version" "$out" "release 1.10.0"
# The date is why kcm-build.env has to be quoted: unquoted it was not readable.
assert_contains "reads the commit date" "$out" "Mon 8.6.2026"
# RUN_ID is the whole selection -- common.sh reads the rest back from the same
# file, so the hint must not tell people to repeat it.
assert_contains "says how to reuse it" "$out" "RUN_ID=demo"
assert_not_contains "without repeating the selection" "$out" "KCM=rel-1-10-0"
assert_contains "separates the leftover workdir" "$out" "ghost"

# A value with spaces must be data, never something the shell runs.
printf "KCM_CHART_VERSION='1.10.0'\nKCM_MODE=release; touch %s/pwned\n" "$work" > "$work/kcm-build.env"
KCM='' bash "$SCRIPTS_DIR/status.sh" >/dev/null 2>&1
assert_eq "kcm-build.env is read, not executed" 1 "$([[ -e "$work/pwned" ]]; echo $?)"

rm -rf "$work" "$REPO_ROOT/.work-ghost" "$MOCK_BIN"
finish
