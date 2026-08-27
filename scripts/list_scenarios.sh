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
while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$have_yq" != "true" ]]; then
        echo "  $id"
        continue
    fi
    desc="$(yq -r '.description // ""' "$SCENARIOS_DIR/$id.yaml" 2>/dev/null | tr '\n' ' ')"
    printf '  %-22s %s\n' "$id" "${desc:0:100}"
    # Its own line, so a long description cannot push it out of sight.
    known="$(yq -r '[.knownFailures[].kcm] | join(", ")' "$SCENARIOS_DIR/$id.yaml" 2>/dev/null)"
    [[ -n "$known" ]] && printf '  %-22s ⚠️  known to fail on: %s\n' "" "$known"
done < <(list_scenarios)

echo
echo "KCM variants (pick with KCM=<id>):"
while read -r id; do
    [[ -n "$id" ]] || continue
    printf '  %-24s %s\n' "$id" "$(kcm_variant_field "$id" name)"
done < <(list_kcm_variants)

echo
echo "Example: make e2e SCENARIO=02_depends_on_valid KCM=rel-1-11-0"
