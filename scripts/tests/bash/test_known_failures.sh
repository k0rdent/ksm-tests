#!/bin/bash
# ci_step.sh: a recorded failure becomes a warning, anything else stays fatal.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

BIN_DIR="$REPO_ROOT/.work/bin"
export BIN_DIR
PATH="$BIN_DIR:$PATH"
if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "  ! mikefarah/yq not installed, skipping"
    exit 0
fi

# shellcheck source=scripts/lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

STEP="Remove services"
MATCH="ensure CRDs are installed first"

# run_step SCENARIO KCM STEP SCRIPT -> "<exit code>|<output>"
run_step() {
    local out rc
    out="$(SCENARIO="$1" KCM="$2" bash -c \
        "unset SERVICES_FILE MCS_TIMEOUT CLD_REMOVAL_TIMEOUT
         '$SCRIPTS_DIR/ci_step.sh' '$3' $4" 2>&1)"
    rc=$?
    echo "$rc|$out"
}

fail_with() { # a script that fails printing $1
    local f; f="$(mktemp)"
    { echo '#!/bin/bash'; echo "echo \"$1\""; echo 'exit 1'; } > "$f"
    chmod +x "$f"; echo "$f"
}

# ── The recorded failure is excused ──────────────────────────────────────────
s="$(fail_with "boom: $MATCH")"
r="$(run_step 02dep01_valid rel-1-11-0 "$STEP" "$s")"
assert_eq "the recorded failure does not fail the step" "0" "${r%%|*}"
assert_contains "and says why" "${r#*|}" "known failure"

# ── Anything else is not ─────────────────────────────────────────────────────
# This is the assertion that matters: without the match, the marker would
# excuse a regression that happens to land on the same leg.
s2="$(fail_with "boom: something else entirely")"
r="$(run_step 02dep01_valid rel-1-11-0 "$STEP" "$s2")"
assert_eq "a different failure still fails" "1" "${r%%|*}"
assert_contains "and explains the mismatch" "${r#*|}" "not with the known defect"

# A failure in a step other than the recorded one is not excused either.
r="$(run_step 02dep01_valid rel-1-11-0 "Deploy services via MultiClusterService" "$s")"
assert_eq "a failure in another step still fails" "1" "${r%%|*}"

# ── Variants with no marker ──────────────────────────────────────────────────
r="$(run_step 02dep01_valid rel-1-10-0 "$STEP" "$s")"
assert_eq "an unmarked variant still fails" "1" "${r%%|*}"
r="$(run_step 01_basic src-main "$STEP" "$s")"
assert_eq "a scenario with no knownFailures still fails" "1" "${r%%|*}"

# ── Success is passed through untouched ──────────────────────────────────────
ok_script="$(mktemp)"; { echo '#!/bin/bash'; echo 'exit 0'; } > "$ok_script"; chmod +x "$ok_script"
r="$(run_step 02dep01_valid rel-1-11-0 "$STEP" "$ok_script")"
assert_eq "a passing step stays passing" "0" "${r%%|*}"
# It still announces the shortened waits, but must not claim it excused
# anything -- that line belongs to the failure path only.
assert_not_contains "and is not excused as a known failure" "${r#*|}" "Not failing the job"

# ── The markers themselves ───────────────────────────────────────────────────
# A marker with no match would silently widen to "ignore everything here".
while read -r id; do
    [[ -n "$id" ]] || continue
    f="$SCENARIOS_DIR/$id.yaml"
    while read -r kcm; do
        [[ -n "$kcm" ]] || continue
        assert_not_eq "$id/$kcm records a matching string" "" \
            "$(KCMID="$kcm" yq -r '.knownFailures[] | select(.kcm == strenv(KCMID)) | .match // ""' "$f")"
        assert_not_eq "$id/$kcm names the step" "" \
            "$(KCMID="$kcm" yq -r '.knownFailures[] | select(.kcm == strenv(KCMID)) | .step // ""' "$f")"
    done < <(yq -r '.knownFailures[]?.kcm' "$f")
done < <(list_scenarios)

rm -f "$s" "$s2" "$ok_script"
finish
