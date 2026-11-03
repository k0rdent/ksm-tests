#!/usr/bin/env bash
# Where the run spent its time: one line per phase, in the order they ran.
#
#   ./scripts/report.sh
#
# The phases write themselves into $TIMINGS_FILE as they finish -- see
# record_phase in scripts/lib/common.sh. Nothing here talks to a cluster, so it
# is safe from CI's always() after everything else has been torn down.
#
# Never fatal: this is a report, and a run that passed must not go red because
# the report could not be printed.
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ ! -s "$TIMINGS_FILE" ]]; then
    log "No phases recorded -- nothing ran, or it failed before the first one"
    exit 0
fi

step "Where the time went"

total=0
failed=0
rows=()
while IFS=$'\t' read -r label secs status; do
    [[ -n "$label" ]] || continue
    total=$(( total + secs ))
    (( status == 0 )) || failed=$(( failed + 1 ))
    printf '   %-40s %3dm%02ds  %s\n' \
        "$label" "$(( secs / 60 ))" "$(( secs % 60 ))" \
        "$( (( status == 0 )) && echo "ok" || echo "FAILED" )"
    # Marked only when it failed, so a green run's table reads as plainly as
    # catalog's does.
    rows+=("| $label | $(printf '%dm %02ds' "$(( secs / 60 ))" "$(( secs % 60 ))")\
$( (( status == 0 )) || echo ' ❌') |")
done < "$TIMINGS_FILE"

printf '   %-40s %3dm%02ds\n' "total" "$(( total / 60 ))" "$(( total % 60 ))"

# The phases are not the whole job -- installing KCM, applying the Release and
# waiting for templates are not timed -- so say what this adds up, rather than
# letting the total read as the wall clock.
log ""
log "Timed phases only; the environment build in between is not counted."
(( failed )) && log "$failed phase(s) failed."

# And onto the run's summary page, the way k0rdent/catalog does it. The console
# table above is inside a step nobody expands, and the durations are what gets
# looked up again later.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    # What the numbers are for: the build, the mode, and where a provisioned
    # cluster ran. Catalog names its one app here; a run of ours is a set of
    # scenarios, which the table lists anyway.
    ctx="kcm \`${KCM:-?}\` | \`$TEST_MODE\`"
    case "$TEST_MODE" in
        aws)   ctx+=" | \`${AWS_EC2_FAMILY:-?}\` in \`${AWS_REGION:-?}\`" ;;
        azure) ctx+=" | \`${AZURE_LOCATION:-?}\`" ;;
        gcp)   ctx+=" | \`${GCP_REGION:-?}\`" ;;
    esac
    {
        echo "## ${GITHUB_WORKFLOW:-E2E}"
        echo ""
        echo "$ctx"
        echo ""
        echo "| Phase | Duration |"
        echo "| --- | --- |"
        printf '%s\n' "${rows[@]}"
        printf '| **total** | **%dm %02ds** |\n' "$(( total / 60 ))" "$(( total % 60 ))"
        echo ""
        echo "Timed phases only; the environment build in between is not counted."
    } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
