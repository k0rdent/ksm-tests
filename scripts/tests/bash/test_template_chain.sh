#!/bin/bash
# ServiceTemplateChain scenarios and the versions they need.
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

# ── Scenarios without a chain are unaffected ─────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/01_basic.yaml"
assert_eq "01_basic has no chain" "1" "$(has_template_chain && echo 0 || echo 1)"
assert_eq "and no upgrade steps" "0" "$(upgrade_steps)"
SERVICES_FILE="$SCENARIOS_DIR/03upg01_valid.yaml"
assert_eq "the plain upgrade scenario has no steps either" "0" "$(upgrade_steps)"

# ── 05chain01: steps but no chain ────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/05chain01_no_chain.yaml"
assert_eq "no chain is declared" "1" "$(has_template_chain && echo 0 || echo 1)"
assert_eq "one upgrade step" "1" "$(upgrade_steps)"
assert_eq "straight to the latest" "1.21.1" "$(upgrade_step_field 0 version)"
assert_eq "and it must land" "applied" "$(upgrade_step_field 0 expect)"
# Templates are needed for both ends of the step, or there is nothing to move to.
assert_eq "templates are needed for both versions" "1.20.2 1.21.1" \
    "$(all_versions_for cert-manager | tr '\n' ' ' | sed 's/ $//')"

# ── 05chain02: a chain that allows nothing ───────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/05chain02_boundary.yaml"
assert_eq "a chain is declared" "0" "$(has_template_chain && echo 0 || echo 1)"
assert_eq "it names one version" "1.20.2" "$(chain_versions | tr '\n' ' ' | sed 's/ $//')"
# The whole point: no upgrades offered, so the step must be refused.
assert_eq "which offers no upgrades" "" "$(chain_upgrades_for 1.20.2)"
assert_eq "so the step is expected to be rejected" "rejected" "$(upgrade_step_field 0 expect)"

# ── 05chain03: direct jump allowed, intermediate not ─────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/05chain03_direct_to_latest.yaml"
assert_eq "1.20.2 may go straight to 1.21.1" "1.21.1" "$(chain_upgrades_for 1.20.2)"
assert_eq "two steps" "2" "$(upgrade_steps)"
assert_eq "the intermediate is refused" "rejected" "$(upgrade_step_field 0 expect)"
assert_eq "the latest is accepted" "applied" "$(upgrade_step_field 1 expect)"
# The refused target must be a version the chain does NOT offer, or the
# scenario would be asserting something that cannot happen.
assert_not_contains "the refused target is not in the chain's upgrades" \
    "$(chain_upgrades_for 1.20.2)" "$(upgrade_step_field 0 version)"

# ── 05chain04: stepwise ──────────────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/05chain04_stepwise.yaml"
assert_eq "the chain steps through 1.20.3" "1.20.3" "$(chain_upgrades_for 1.20.2)"
assert_eq "and then to 1.21.1" "1.21.1" "$(chain_upgrades_for 1.20.3)"
assert_eq "the step asks for the latest" "1.21.1" "$(upgrade_step_field 0 version)"
assert_eq "and must pass through the intermediate" "1.20.3" \
    "$(upgrade_step_list 0 viaVersions | tr '\n' ' ' | sed 's/ $//')"
# Every version the scenario mentions needs a ServiceTemplate, including the
# intermediate one it is only supposed to pass through.
assert_eq "templates cover the whole path" "1.20.2 1.20.3 1.21.1" \
    "$(all_versions_for cert-manager | tr '\n' ' ' | sed 's/ $//')"

# ── Rendering ────────────────────────────────────────────────────────────────
chain="$(mktemp)"
render_chain "$chain"
assert_eq "the chain object is a ServiceTemplateChain" "ServiceTemplateChain" \
    "$(yq -r '.kind' "$chain")"
assert_eq "with three supported templates" "3" \
    "$(yq -r '.spec.supportedTemplates | length' "$chain")"
# Versions are written as chart versions but must render as template names.
assert_eq "named as templates, not versions" "cert-manager-1-20-2" \
    "$(yq -r '.spec.supportedTemplates[0].name' "$chain")"
assert_eq "with the next hop as a template too" "cert-manager-1-20-3" \
    "$(yq -r '.spec.supportedTemplates[0].availableUpgrades[0].name' "$chain")"
assert_eq "and the last one offers nothing" "null" \
    "$(yq -r '.spec.supportedTemplates[2].availableUpgrades' "$chain")"

mcs="$(mktemp)"
render_mcs "$mcs" initial
assert_eq "the MCS references the chain" "$(chain_name)" \
    "$(yq -r '.spec.serviceSpec.services[0].templateChain' "$mcs")"
assert_eq "and starts on the initial version" "cert-manager-1-20-2" \
    "$(yq -r '.spec.serviceSpec.services[0].template' "$mcs")"

# A step pins the service to that step's version, leaving the chain in place.
UPGRADE_TO=1.21.1 render_mcs_at_version "$mcs"
assert_eq "a step moves the template" "cert-manager-1-21-1" \
    "$(yq -r '.spec.serviceSpec.services[0].template' "$mcs")"
assert_eq "and keeps the chain" "$(chain_name)" \
    "$(yq -r '.spec.serviceSpec.services[0].templateChain' "$mcs")"

tmpl="$(mktemp)"
render_templates "$tmpl" initial
assert_eq "a ServiceTemplate per version on the path" "3" \
    "$(grep -c '^kind: ServiceTemplate' "$tmpl")"

# Every version named anywhere in a chain scenario must get a template, or the
# upgrade would point at something that does not exist.
while read -r id; do
    [[ -n "$id" ]] || continue
    SERVICES_FILE="$SCENARIOS_DIR/$id.yaml"
    has_template_chain || continue
    svc="$(chain_service)"
    known="$(all_versions_for "$svc")"
    while read -r v; do
        [[ -n "$v" ]] || continue
        assert_contains "$id: chain version $v has a template" "$known" "$v"
    done < <(chain_versions)
done < <(list_scenarios)

rm -f "$chain" "$mcs" "$tmpl"
finish
