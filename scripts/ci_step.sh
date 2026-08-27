#!/bin/bash
set -uo pipefail

# Run one pipeline step, and turn a *recorded* failure into a warning.
#
#   ./scripts/ci_step.sh "Remove MultiClusterService" ./scripts/remove_mcs.sh
#
# When the scenario lists the current $KCM under knownFailures, two things
# change:
#
#   the waits are shortened, so the leg stops as soon as it has printed the
#   diagnostics rather than sitting out the full timeout;
#
#   a failure that matches the recorded one is reported as a warning and the
#   step exits 0, so the job stays green with a yellow annotation instead of
#   going red.
#
# The match is on purpose. Without it the marker would excuse *any* failure on
# that leg, and a real regression would disappear behind a known defect.
#
# Actions has no yellow job state -- neutral conclusions only exist in the
# Checks API -- so a warning annotation plus the job summary is as close as it
# gets natively.

STEP_NAME="${1:?usage: ci_step.sh NAME COMMAND...}"
shift

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

known=false
if [[ -f "$SERVICES_FILE" ]] && command -v yq >/dev/null 2>&1 \
   && yq --version 2>&1 | grep -qi mikefarah && is_known_failure; then
    known=true
    KF_REASON="$(known_failure_field reason)"
    KF_STEP="$(known_failure_field step)"
    KF_MATCH="$(known_failure_field match)"
    KF_TIMEOUT="$(known_failure_field timeout)"
    KF_TIMEOUT="${KF_TIMEOUT:-${KNOWN_FAILURE_TIMEOUT:-300}}"

    if [[ -z "$KF_STEP" || "$KF_STEP" == "$STEP_NAME" ]]; then
        # Only the step that is expected to fail gets the short leash; the ones
        # before it still need their normal budget to get that far.
        export MCS_TIMEOUT="$KF_TIMEOUT" CLD_REMOVAL_TIMEOUT="$KF_TIMEOUT"
        export DIAG_INTERVAL="${DIAG_INTERVAL_KNOWN:-60}"
        warn "'$STEP_NAME' is a known failure on $KCM -- waits shortened to ${KF_TIMEOUT}s"
    fi
fi

out="$(mktemp)"
"$@" 2>&1 | tee "$out"
rc="${PIPESTATUS[0]}"

if (( rc == 0 )); then
    rm -f "$out"
    exit 0
fi

fail_hard() { # fail_hard WHY
    rm -f "$out"
    warn "$1"
    exit "$rc"
}

[[ "$known" == "true" ]] || fail_hard "'$STEP_NAME' failed"

if [[ -n "$KF_STEP" && "$KF_STEP" != "$STEP_NAME" ]]; then
    fail_hard "'$STEP_NAME' failed, but the known failure on $KCM is in '$KF_STEP'"
fi
if [[ -n "$KF_MATCH" ]] && ! grep -qF -- "$KF_MATCH" "$out"; then
    fail_hard "'$STEP_NAME' failed, but not with the known defect (no '$KF_MATCH' in the output)"
fi

# Matched: report, do not fail.
summary="known failure on $KCM in '$STEP_NAME' -- $(tr '\n' ' ' <<< "$KF_REASON")"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=Known failure ($SCENARIO / $KCM)::$summary"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### ⚠️ Known failure"
        echo
        echo "| Scenario | KCM | Step |"
        echo "|---|---|---|"
        echo "| \`$SCENARIO\` | \`$KCM\` | $STEP_NAME |"
        echo
        echo "$KF_REASON"
        echo
        echo "Recorded in \`test_scenarios/$SCENARIO.yaml\`. Delete the entry once it is fixed upstream."
    } >> "$GITHUB_STEP_SUMMARY"
fi

rm -f "$out"
warn "$summary"
log "Not failing the job: this is recorded in test_scenarios/$SCENARIO.yaml"
exit 0
