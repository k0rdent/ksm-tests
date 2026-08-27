#!/bin/bash
# KCM=<id> resolution, and the link between variants and scenario knownFailures.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

# This test process has already sourced common.sh, which exports the three
# variables; the child would inherit them and the variant lookup would never
# apply. Unset them so we measure resolution, not inheritance.
var_of() { # var_of KCM VAR
    KCM="$1" bash -c "
        unset KCM_SOURCE KCM_REF KCM_RELEASE_VERSION
        source '$SCRIPTS_DIR/lib/common.sh'
        echo \"\${$2}\""
}

# ── Resolution ───────────────────────────────────────────────────────────────
assert_eq "src-main builds from source" "source" "$(var_of src-main KCM_SOURCE)"
assert_eq "src-main follows main" "main" "$(var_of src-main KCM_REF)"

assert_eq "rel-1-11-0 uses the release chart" "release" "$(var_of rel-1-11-0 KCM_SOURCE)"
assert_eq "rel-1-11-0 pins the version" "1.11.0" "$(var_of rel-1-11-0 KCM_RELEASE_VERSION)"
# common.sh derives the tag from the version, so the checkout matches the chart.
assert_eq "rel-1-11-0 checks out the matching tag" "v1.11.0" "$(var_of rel-1-11-0 KCM_REF)"

assert_eq "rel-1-10-0 pins its own version" "1.10.0" "$(var_of rel-1-10-0 KCM_RELEASE_VERSION)"

# Without KCM the old defaults still apply, so nothing that sets the three
# variables directly has to change.
assert_eq "no KCM keeps the source default" "source" \
    "$(bash -c "unset KCM KCM_SOURCE; source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_SOURCE")"

# An ad-hoc version that is not a declared variant must stay testable.
got="$(KCM=rel-1-11-0 KCM_RELEASE_VERSION=1.9.0 bash -c \
    "unset KCM_SOURCE KCM_REF; source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_RELEASE_VERSION")"
assert_eq "an explicit version overrides the variant" "1.9.0" "$got"

# ── Typos ────────────────────────────────────────────────────────────────────
out=$(KCM=nope bash -c "source '$SCRIPTS_DIR/lib/common.sh'" 2>&1)
assert_eq "an unknown variant is rejected" 1 "$?"
assert_contains "names the bad value" "$out" "nope"
assert_contains "lists what is available" "$out" "rel-1-11-0"

# ── Variants and scenarios must agree ────────────────────────────────────────
# A typo in knownFailures would not fail anything -- the marker would simply
# never match, and CI would go red without explanation. Catch it here instead.
ids="$(list_kcm_variants)"
while read -r scenario; do
    [[ -n "$scenario" ]] || continue
    file="$SCENARIOS_DIR/$scenario.yaml"
    command -v yq >/dev/null 2>&1 || break
    yq --version 2>&1 | grep -qi mikefarah || break
    while read -r kcm; do
        [[ -n "$kcm" ]] || continue
        TESTS_RUN=$((TESTS_RUN + 1))
        if grep -qx "$kcm" <<< "$ids"; then
            echo "  ✓ $scenario knownFailures references a real variant: $kcm"
        else
            echo "  ✗ $scenario knownFailures references unknown variant '$kcm'"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done < <(yq -r '.knownFailures[].kcm' "$file" 2>/dev/null)
done < <(list_scenarios)

finish
