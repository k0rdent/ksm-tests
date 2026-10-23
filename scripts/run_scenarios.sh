#!/usr/bin/env bash
# One cluster, several scenarios, one after another. No `set -e`: the loop
# decides what a failure means, and it still has a summary to print.
set -uo pipefail

# Run a set of scenarios against ./kcfg_k0rdent, in order.
#
#   export SCENARIOS="101_basic 201_svcdep"   # empty = every scenario
#   ./scripts/run_scenarios.sh
#
# Each scenario removes its own services, so the next one starts from the same
# cluster state -- remove_services.sh asserts that, which is what makes sharing
# a cluster safe.
#
# The run stops at the first failure: on a shared cluster the ones after it
# would be starting from a state nobody asserted anyway, and the environment
# costs minutes that a known-bad run should not spend.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_yq
require_cluster

WANTED="${SCENARIOS:-}"
if [[ -z "${WANTED// /}" ]]; then
    for f in "$SCENARIOS_DIR"/*.yaml; do WANTED+=" $(basename "$f" .yaml)"; done
fi

# Commas as well as spaces: the CI input is a comma-separated list.
WANTED="${WANTED//,/ }"

ordered=() skipped=()
for id in $WANTED; do
    file="$SCENARIOS_DIR/$id.yaml"
    # Checked up front, so a typo in the list fails before an hour of cluster
    # build rather than after it.
    [[ -f "$file" ]] || die "Unknown scenario '$id' -- no $file"
    # A scenario locked to the other mode is left out rather than run: one
    # environment serves the whole list, and check_scenario would refuse it
    # anyway -- which would end the run instead of skipping one scenario.
    want="$(yq -r '.testMode // ""' "$file")"
    if [[ -n "$want" && "$want" != "$TEST_MODE" ]]; then
        skipped+=("$id ($want)")
    else
        ordered+=("$id")
    fi
done
(( ${#ordered[@]} )) || die "No scenarios to run in TEST_MODE=$TEST_MODE"

step "Serial run: ${#ordered[@]} scenario(s) in TEST_MODE=$TEST_MODE on $(basename "$(readlink -f "$KUBECONFIG_MGMT")")"
printf '   %s\n' "${ordered[@]}"
(( ${#skipped[@]} )) && log "Not for this mode: ${skipped[*]}"

export KUBECONFIG="$KUBECONFIG_MGMT"

# The next scenario has to start from the state the last one started from.
# remove_services.sh asserts its own objects are gone; this asserts nothing
# else is left either, because a stray MultiClusterService surfaces as a
# failure somewhere unrelated two scenarios later.
assert_cluster_clean() {
    local left
    left="$(kube get multiclusterservice -n "$NAMESPACE" -o name 2>/dev/null || true)"
    [[ -z "$left" ]] && return 0
    warn "MultiClusterService still on the cluster after $1:"
    # shellcheck disable=SC2001 # per-line prefix, not a substring replace
    sed 's/^/     /' <<< "$left" >&2
    return 1
}

declare -A RESULT ELAPSED
FAILED=""
n=0
RUN_START=$SECONDS

for id in "${ordered[@]}"; do
    n=$(( n + 1 ))
    step "[$n/${#ordered[@]}] $id"
    start=$SECONDS
    # A log directory per scenario: collect_logs.sh writes into $LOG_DIR, and
    # a shared one would leave only the last failure behind. CI uploads logs*/.
    # The unsets matter: sourcing the library above exported SERVICES_FILE and
    # MCS_NAME for whatever SCENARIO was current then, and a child honours the
    # inherited pair over its own SCENARIO. That ran 101_basic eleven times
    # under eleven names, and passed.
    if env -u SERVICES_FILE -u MCS_NAME \
        SCENARIO="$id" SCENARIO_KEEP=false LOG_DIR="$PROJECT_ROOT/logs-$id" \
        "$SCRIPTS_DIR/run_scenario.sh"; then
        if assert_cluster_clean "$id"; then
            RESULT["$id"]="passed"
        else
            RESULT["$id"]="UNCLEAN"
            FAILED="$id"
        fi
    else
        RESULT["$id"]="FAILED"
        FAILED="$id"
    fi
    ELAPSED["$id"]=$(( SECONDS - start ))
    [[ -n "$FAILED" ]] && break
done

# Says what was never attempted as well as what ran: a summary listing three
# scenarios after a run that stopped at the first would read as three verdicts.
step "Summary"
for id in "${ordered[@]}"; do
    printf '   %-28s %-9s %s\n' "$id" "${RESULT[$id]:-not run}" \
        "$( [[ -n "${ELAPSED[$id]:-}" ]] \
            && printf '%dm%02ds' "$(( ELAPSED[$id] / 60 ))" "$(( ELAPSED[$id] % 60 ))" )"
done
log "Total $(( (SECONDS - RUN_START) / 60 ))m$(( (SECONDS - RUN_START) % 60 ))s"

if [[ -n "$FAILED" ]]; then
    die "$FAILED failed -- stopping, $(( ${#ordered[@]} - n )) scenario(s) not run"
fi
ok "All ${#ordered[@]} scenarios passed"
