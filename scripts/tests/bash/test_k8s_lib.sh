#!/bin/bash
# Tests for scripts/lib/k8s.sh against a mocked kubectl.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_mock_bin
STATE="$MOCK_BIN/state"

# Mock kubectl: prints $STATE for jsonpath queries, exits 1 when it holds ABSENT.
write_mock kubectl <<'EOF'
#!/bin/bash
state="$(cat "$MOCK_BIN/state" 2>/dev/null)"
[[ "$state" == "ABSENT" ]] && exit 1
for arg in "$@"; do
    case "$arg" in
        -o|--output) continue ;;
        jsonpath=*|yaml) echo "$state"; exit 0 ;;
    esac
done
echo "$state"
EOF

# shellcheck source=scripts/lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

echo True > "$STATE"
assert_eq "condition_status returns the status" "True" "$(condition_status Management kcm "" Ready)"

out=$(wait_for_condition Management kcm "" Ready 10 1 2>&1)
assert_eq "wait_for_condition -> 0 when True" 0 "$?"
assert_contains "reports readiness" "$out" "is Ready"

echo False > "$STATE"
out=$(wait_for_condition Management kcm "" Ready 2 1 2>&1)
assert_eq "wait_for_condition -> 1 on timeout" 1 "$?"
assert_contains "reports the timeout" "$out" "Timeout"

echo ABSENT > "$STATE"
assert_eq "resource_exists -> false when absent" 1 "$(resource_exists Management kcm; echo $?)"
out=$(wait_for_absence ClusterDeployment docker-e2e kcm-system 10 1 2>&1)
assert_eq "wait_for_absence -> 0 when absent" 0 "$?"
assert_contains "reports removal" "$out" "is gone"

echo present > "$STATE"
out=$(wait_for_absence ClusterDeployment docker-e2e kcm-system 2 1 2>&1)
assert_eq "wait_for_absence -> 1 while present" 1 "$?"

rm -rf "$MOCK_BIN"
finish
