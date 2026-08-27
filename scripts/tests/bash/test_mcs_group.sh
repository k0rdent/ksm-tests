#!/bin/bash
# Scenarios that declare several MultiClusterServices.
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

# ── The flat form must keep behaving exactly as before ───────────────────────
SERVICES_FILE="$SCENARIOS_DIR/01_basic.yaml"
assert_eq "a flat scenario is not multi-MCS" "1" "$(is_multi_mcs && echo 0 || echo 1)"
assert_eq "and counts as one MCS" "1" "$(mcs_count)"
assert_eq "its object name is unsuffixed" "$MCS_NAME" "$(mcs_object_name 0)"
assert_eq "its services are still readable" "1" "$(service_count)"

# ── 04mcs01_valid ────────────────────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/04mcs01_valid.yaml"
assert_eq "declares two MultiClusterServices" "2" "$(mcs_count)"
assert_eq "is recognised as multi-MCS" "0" "$(is_multi_mcs && echo 0 || echo 1)"
assert_eq "first is base" "base" "$(mcs_key 0)"
assert_eq "second is dependent" "dependent" "$(mcs_key 1)"
assert_eq "dependent depends on base" "base" "$(mcs_depends_on 1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "base depends on nothing" "" "$(mcs_depends_on 0 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "keys resolve back to indexes" "1" "$(mcs_index_of dependent)"

# Object names must differ, or the two MCSs would collide in the cluster.
assert_not_eq "the object names differ" "$(mcs_object_name 0)" "$(mcs_object_name 1)"
assert_contains "and carry the key" "$(mcs_object_name 1)" "-dependent"

# Services are read per MCS, not globally.
assert_eq "base has one service" "1" "$(MCS_IDX=0 service_count)"
assert_eq "and it is cert-manager" "cert-manager" \
    "$(MCS_IDX=0 services_rows | cut -d'|' -f1)"
assert_eq "dependent has traefik" "traefik" \
    "$(MCS_IDX=1 services_rows | cut -d'|' -f1)"
# Templates and teardown need the union.
assert_eq "all_services_rows spans both" "cert-manager traefik" \
    "$(all_services_rows | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "namespaces span both" "cert-manager traefik" \
    "$(all_service_namespaces | tr '\n' ' ' | sed 's/ $//')"

# ── Rendering ────────────────────────────────────────────────────────────────
base="$(mktemp)"; dep="$(mktemp)"
MCS_IDX=0 render_mcs "$base" initial
MCS_IDX=1 render_mcs "$dep" initial

assert_eq "base renders no dependsOn" "null" "$(yq -r '.spec.dependsOn' "$base")"
assert_eq "dependent renders one" "1" "$(yq -r '.spec.dependsOn | length' "$dep")"
# It must reference the real object name, not the scenario's short key -- KCM
# looks the dependency up by name and would never find "base".
assert_eq "and points at the real object" "$(mcs_object_name 0)" \
    "$(yq -r '.spec.dependsOn[0]' "$dep")"
assert_eq "each renders only its own services" "traefik" \
    "$(yq -r '.spec.serviceSpec.services[].name' "$dep" | tr '\n' ' ' | sed 's/ $//')"

# Templates cover every MCS, or the dependent one could never deploy.
tmpl="$(mktemp)"
render_templates "$tmpl" initial
assert_eq "templates are rendered for both" "2" "$(grep -c '^kind: ServiceTemplate' "$tmpl")"

# ── 04mcs02_invalid_dependency ───────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/04mcs02_invalid_dependency.yaml"
assert_eq "the dependent one must never deploy" "dependent" \
    "$(expect_list neverDeployed | tr '\n' ' ' | sed 's/ $//')"
assert_eq "with a grace window" "180" "$(expect_field graceSeconds)"
# The point of the scenario is that base is broken; if its values were valid
# the dependent would deploy and the assertion would never fire.
assert_contains "base declares the invalid value" "$(MCS_IDX=0 service_values cert-manager)" \
    "replicaCount: -1"
assert_eq "and dependent still depends on it" "base" \
    "$(mcs_depends_on 1 | tr '\n' ' ' | sed 's/ $//')"

# Every name in expect must be a real MCS key, same trap as elsewhere.
keys=""
for i in 0 1; do keys+="$(mcs_key "$i") "; done
for f in neverDeployed orderedAfterDependencies; do
    while read -r n; do
        [[ -n "$n" ]] || continue
        assert_contains "expect.$f '$n' is a declared MCS" "$keys" "$n"
    done < <(expect_list "$f")
done
SERVICES_FILE="$SCENARIOS_DIR/04mcs01_valid.yaml"
while read -r n; do
    [[ -n "$n" ]] || continue
    assert_contains "expect.orderedAfterDependencies '$n' is a declared MCS" "$keys" "$n"
    assert_not_eq "and '$n' actually declares a dependency" "" \
        "$(mcs_depends_on "$(mcs_index_of "$n")")"
done < <(expect_list orderedAfterDependencies)

rm -f "$base" "$dep" "$tmpl"
finish
