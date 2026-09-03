#!/bin/bash
set -euo pipefail

# List the available scenarios and KCM variants.
#
#   ./scripts/list_scenarios.sh          human-readable, with descriptions
#   ./scripts/list_scenarios.sh --ids    just the scenario stems, for scripting

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ "${1:-}" == "--ids" ]]; then
    list_scenarios
    exit 0
fi

have_yq=false
if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah; then
    have_yq=true
fi

echo "Scenarios (test_scenarios/, pick with SCENARIO=<id>):"
# Two layers: the group heading, then its cases. Groups appear in the order
# their first scenario does, which the numeric stems already sort correctly.
last_group=""
while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$have_yq" != "true" ]]; then
        echo "  $id"
        continue
    fi
    file="$SCENARIOS_DIR/$id.yaml"

    group="$(yq -r '.group // "Ungrouped"' "$file" 2>/dev/null)"
    if [[ "$group" != "$last_group" ]]; then
        echo
        echo "  $group"
        last_group="$group"
    fi

    desc="$(yq -r '.description // ""' "$file" 2>/dev/null | tr '\n' ' ')"
    printf '    %-24s %s\n' "$id" "${desc:0:96}"
    # Each on its own line, so a long description cannot push them out of sight.
    known="$(yq -r '[.knownFailures[].kcm] | join(", ")' "$file" 2>/dev/null)"
    [[ -n "$known" ]] && printf '    %-24s ⚠️  known to fail on: %s\n' "" "$known"
    failed="$(yq -r '.expect.failed // ""' "$file" 2>/dev/null)"
    [[ -n "$failed" ]] && printf '    %-24s ⛔ expects "%s" to fail\n' "" "$failed"
done < <(list_scenarios)

echo
echo "KCM variants (pick with KCM=<id>; these are what CI runs):"
while read -r id; do
    [[ -n "$id" ]] || continue
    printf '  %-24s %s\n' "$id" "$(kcm_variant_field "$id" name)"
done < <(list_kcm_variants)

echo
echo "Example: make e2e SCENARIO=02dep01_valid KCM=rel-1-11-0"
echo "Anything else: KCM_VERSION=<v>, or KCM_MODE=source with KCM_SRC_URL/KCM_REF."
