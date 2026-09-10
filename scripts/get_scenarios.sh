#!/bin/bash
set -euo pipefail

# The available scenarios, one per line, with what each asserts.
#
#   ./scripts/get_scenarios.sh

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

have_yq=false
if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah; then
    have_yq=true
fi

while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$have_yq" != "true" ]]; then
        echo "$id"
        continue
    fi
    desc="$(yq -r '.description // ""' "$SCENARIOS_DIR/$id.yaml" 2>/dev/null | tr '\n' ' ')"
    printf '%-26s # %s\n' "$id" "${desc:0:96}"
done < <(list_scenarios)
