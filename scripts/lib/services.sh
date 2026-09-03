#!/bin/bash
# Helpers for reading $SERVICES_FILE. Expects common.sh to be sourced first.

# ── One or several MultiClusterServices ──────────────────────────────────────
# A flat `services:` list gives one MCS; `multiClusterServices:` gives several,
# and the accessors below then read the one selected by $MCS_IDX.

is_multi_mcs() {
    [[ "$(yq -r '.multiClusterServices // "" | tag' "$SERVICES_FILE")" == "!!seq" ]]
}

# mcs_count -- how many MultiClusterServices the scenario declares.
mcs_count() {
    if is_multi_mcs; then yq -r '.multiClusterServices | length' "$SERVICES_FILE"; else echo 1; fi
}

# mcs_root -- the yq path prefix for the currently selected MCS.
mcs_root() {
    if is_multi_mcs; then echo ".multiClusterServices[${MCS_IDX:-0}]"; else echo ""; fi
}

# mcs_key IDX -- the short name the scenario gave this MCS, empty in flat form.
mcs_key() {
    is_multi_mcs || return 0
    IDX="$1" yq -r '.multiClusterServices[env(IDX)].name' "$SERVICES_FILE"
}

# mcs_object_name IDX -- the Kubernetes name, unique per run and scenario.
mcs_object_name() {
    local key
    key="$(mcs_key "$1")"
    [[ -n "$key" ]] && echo "$MCS_NAME-$key" || echo "$MCS_NAME"
}

# mcs_depends_on IDX -- the MCS keys this one depends on, one per line.
mcs_depends_on() {
    is_multi_mcs || return 0
    IDX="$1" yq -r '.multiClusterServices[env(IDX)].dependsOn[]? // ""' "$SERVICES_FILE"
}

# mcs_index_of KEY -- position of the MCS with this short name.
mcs_index_of() {
    KEY="$1" yq -r \
        '.multiClusterServices | to_entries[] | select(.value.name == strenv(KEY)) | .key' \
        "$SERVICES_FILE"
}

# service_count -- how many services are declared.
service_count() {
    yq -r "$(mcs_root).services | length" "$SERVICES_FILE"
}

# Not whitespace: a whitespace IFS collapses runs and drops empty fields, which
# shifted every value after an empty dependsOn.
# shellcheck disable=SC2034 # used by the scripts that source this
SERVICE_SEP='|'

# services_rows -- one line per service, SERVICE_SEP separated:
#   name|chart|version|repo|namespace|dependsOn|waitForPods
services_rows() {
    yq -r "$(mcs_root).services[] | [.name, .chart, .version, .repo, .namespace,
                          (.dependsOn // \"\"), (.waitForPods // \"\")] | join(\"|\")" "$SERVICES_FILE"
}

# all_services_rows -- every service across every MCS (templates, teardown).
all_services_rows() {
    local i
    if ! is_multi_mcs; then services_rows; return; fi
    for (( i = 0; i < $(mcs_count); i++ )); do
        MCS_IDX="$i" services_rows
    done
}

# service_namespaces -- each target namespace once, in declaration order.
service_namespaces() {
    yq -r "$(mcs_root).services[].namespace" "$SERVICES_FILE" | awk '!seen[$0]++'
}

# all_service_namespaces -- likewise across every MCS.
all_service_namespaces() {
    all_services_rows | cut -d'|' -f5 | awk 'NF && !seen[$0]++'
}

# service_values NAME -- the values block for one service, empty if it has none.
service_values() {
    NAME="$1" yq -r "$(mcs_root).services[] | select(.name == strenv(NAME)) | .values // \"\"" "$SERVICES_FILE"
}

# service_field NAME FIELD
service_field() {
    NAME="$1" FIELD="$2" yq -r \
        "$(mcs_root).services[] | select(.name == strenv(NAME)) | .[strenv(FIELD)] // \"\"" "$SERVICES_FILE"
}

# template_name_for CHART VERSION -- the ServiceTemplate name, matching the
# <chart>-<version with dashes> convention KCM uses everywhere else.
template_name_for() {
    echo "$1-$(fqdn_version "$2")"
}

# ── Known failures ───────────────────────────────────────────────────────────
# The entry names a step and a fragment of the expected error, so a leg that
# breaks for another reason still goes red rather than being swallowed.

# known_failure_field FIELD -- from the entry matching $KCM, empty otherwise.
known_failure_field() {
    KCMID="${KCM:-}" FIELD="$1" yq -r \
        '.knownFailures[]? | select(.kcm == strenv(KCMID)) | .[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

# is_known_failure -- true when this scenario is expected to fail on this KCM.
is_known_failure() {
    [[ -n "${KCM:-}" ]] || return 1
    [[ -n "$(known_failure_field kcm)" ]]
}

# ── Upgrades ─────────────────────────────────────────────────────────────────
# An `upgrade:` block deploys once, changes some services, then asserts what
# moved and what did not.

has_upgrade() {
    [[ "$(yq -r '.upgrade // "" | tag' "$SERVICES_FILE")" == "!!map" ]]
}

# upgrade_names -- the services the upgrade touches, one per line.
upgrade_names() {
    yq -r '.upgrade.services[]?.name // ""' "$SERVICES_FILE"
}

# upgrade_field NAME FIELD -- an override for one service, empty if unset.
upgrade_field() {
    NAME="$1" FIELD="$2" yq -r \
        '.upgrade.services[]? | select(.name == strenv(NAME)) | .[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

# Sveltos keeps two helm revisions per release, which is fewer than a chain
# scenario needs: the path it took is only provable while the revisions it
# passed through still exist.
HELM_MAX_HISTORY="${HELM_MAX_HISTORY:-10}"

# scenario_helm_options [INDENT] -- the helmOptions block every service gets,
# indented and ready to append. The scenario's own helmOptions are merged over
# the defaults, so it can override any of them.
#
# Rendered from the first install on, not just at upgrade time: adding
# helmOptions later makes sveltos reinstall instead of upgrade.
scenario_helm_options() {
    local indent="${1:-10}"
    HELM_DEFAULTS="{upgradeOptions: {maxHistory: $HELM_MAX_HISTORY}}" \
        yq -r '(env(HELM_DEFAULTS) * (.helmOptions // {}))' "$SERVICES_FILE" \
        | sed "s/^/$(printf '%*s' "$indent" '')/"
}

upgrade_expect_field() {
    FIELD="$1" yq -r '.upgrade.expect[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

upgrade_expect_list() {
    FIELD="$1" yq -r '.upgrade.expect[strenv(FIELD)][]? // ""' "$SERVICES_FILE"
}

# effective_version NAME MODE [FALLBACK] -- the version this service should be
# at. FALLBACK is needed when iterating across MCSs: service_field only sees the
# selected one, and an empty result renders as "traefik-".
effective_version() {
    local v
    # A chain scenario walks one step at a time, pinning the service to the
    # version that step is trying to move to.
    if [[ "${2:-}" == "step" && -n "${STEP_VERSION:-}" ]]; then
        echo "$STEP_VERSION"; return
    fi
    if [[ "${2:-}" == "upgraded" ]]; then
        v="$(upgrade_field "$1" version)"
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    v="$(service_field "$1" version)"
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "${3:-}"
}

# effective_values NAME MODE -- likewise. An override replaces rather than
# merges, so a key can be removed.
effective_values() {
    local v
    if [[ "${2:-}" == "upgraded" ]]; then
        v="$(upgrade_field "$1" values)"
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    service_values "$1"
}

# ── ServiceTemplateChains and stepwise upgrades ──────────────────────────────
# Scenarios write chart versions; the ServiceTemplate names are derived.

has_template_chain() {
    [[ "$(yq -r '.templateChain // "" | tag' "$SERVICES_FILE")" == "!!map" ]]
}

chain_name() {
    local n
    n="$(yq -r '.templateChain.name // ""' "$SERVICES_FILE")"
    echo "${n:-chain-$SCENARIO_SLUG}"
}

# chain_service -- chain scenarios cover one application, so the first one.
chain_service() {
    services_rows | head -1 | cut -d'|' -f1
}

# chain_versions -- every version named in supportedTemplates.
chain_versions() {
    yq -r '.templateChain.supportedTemplates[]?.version // ""' "$SERVICES_FILE"
}

# chain_upgrades_for VERSION -- the versions reachable from it in one step.
chain_upgrades_for() {
    V="$1" yq -r \
        '.templateChain.supportedTemplates[]? | select(.version == strenv(V)) | .availableUpgrades[]? // ""' \
        "$SERVICES_FILE"
}

# upgrade_steps -- how many sequential upgrades the scenario performs.
upgrade_steps() {
    yq -r '[.upgrade.steps[]?] | length' "$SERVICES_FILE"
}

upgrade_step_field() { # upgrade_step_field IDX FIELD
    IDX="$1" FIELD="$2" yq -r '.upgrade.steps[env(IDX)][strenv(FIELD)] // ""' "$SERVICES_FILE"
}

upgrade_step_list() { # upgrade_step_list IDX FIELD
    IDX="$1" FIELD="$2" yq -r '.upgrade.steps[env(IDX)][strenv(FIELD)][]? // ""' "$SERVICES_FILE"
}

# all_versions_for NAME -- every version needing a ServiceTemplate: declared,
# named by the chain, or an upgrade target.
all_versions_for() {
    { service_field "$1" version
      chain_versions
      local i
      for (( i = 0; i < $(upgrade_steps); i++ )); do upgrade_step_field "$i" version; done
    } | awk 'NF && !seen[$0]++'
}

# render_mcs_at_version FILE -- the MCS with the service pinned to $UPGRADE_TO.
render_mcs_at_version() {
    STEP_VERSION="$UPGRADE_TO" render_mcs "$1" step
}

# render_chain FILE -- the ServiceTemplateChain object.
# shellcheck disable=SC2153 # NAMESPACE is from common.sh, not a typo
render_chain() {
    local out="$1" svc chart v up
    svc="$(chain_service)"
    chart="$(service_field "$svc" chart)"
    cat > "$out" <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ServiceTemplateChain
metadata:
  name: $(chain_name)
  namespace: $NAMESPACE
spec:
  supportedTemplates:
EOF
    while read -r v; do
        [[ -n "$v" ]] || continue
        echo "    - name: $(template_name_for "$chart" "$v")" >> "$out"
        local first=true
        while read -r up; do
            [[ -n "$up" ]] || continue
            $first && { echo "      availableUpgrades:" >> "$out"; first=false; }
            echo "        - name: $(template_name_for "$chart" "$up")" >> "$out"
        done < <(chain_upgrades_for "$v")
    done < <(chain_versions)
}

# render_templates FILE MODE -- a HelmRepository and ServiceTemplate per
# service and version. Unchanged entries render identically, so re-applying is
# a no-op for them.
# shellcheck disable=SC2153 # NAMESPACE is from common.sh, not a typo for $_ns
render_templates() {
    local out="$1" mode="${2:-initial}"
    : > "$out"
    local name chart version repo _ns _dep _wait tmpl
    while IFS="$SERVICE_SEP" read -r name chart version repo _ns _dep _wait; do
        [[ -n "$name" ]] || continue
        # Every version the scenario can move between, not just the current.
        local versions
        versions="$({ effective_version "$name" "$mode" "$version"; all_versions_for "$name"; } \
                    | awk 'NF && !seen[$0]++')"
        local v
        for v in $versions; do
        version="$v"
        tmpl="$(template_name_for "$chart" "$version")"
        cat >> "$out" <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: $name
  namespace: $NAMESPACE
  labels:
    # KCM runs flux with --watch-label-selector=k0rdent.mirantis.com/managed=true.
    # Without this label source-controller never sees the repository, and the
    # HelmChart fails with a misleading "HelmRepository not found".
    k0rdent.mirantis.com/managed: "true"
spec:
  type: $(repo_type "$repo")
  interval: 10m0s
  url: $repo
---
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ServiceTemplate
metadata:
  name: $tmpl
  namespace: $NAMESPACE
spec:
  helm:
    chartSpec:
      chart: $chart
      version: $version
      interval: 10m0s
      sourceRef:
        kind: HelmRepository
        name: $name
EOF
        done
    done < <(all_services_rows)
}

# render_mcs FILE MODE -- shared by the initial deploy and the upgrade, so the
# two cannot drift apart.
render_mcs() {
    local out="$1" mode="${2:-initial}"

    cat > "$out" <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: MultiClusterService
metadata:
  name: $(mcs_object_name "${MCS_IDX:-0}")
spec:
  clusterSelector:
    matchLabels:
      group: $CLD_GROUP_LABEL
EOF

    # Holds the whole MCS back until the named ones are deployed and healthy.
    local dep first=true
    while read -r dep; do
        [[ -n "$dep" ]] || continue
        $first && { echo "  dependsOn:" >> "$out"; first=false; }
        echo "    - $(mcs_object_name "$(mcs_index_of "$dep")")" >> "$out"
    done < <(mcs_depends_on "${MCS_IDX:-0}")

    cat >> "$out" <<EOF
  serviceSpec:
    services:
EOF

    local name chart version _repo namespace dep _wait values
    while IFS="$SERVICE_SEP" read -r name chart version _repo namespace dep _wait; do
        [[ -n "$name" ]] || continue
        version="$(effective_version "$name" "$mode" "$version")"
        {
            echo "      - template: $(template_name_for "$chart" "$version")"
            echo "        name: $name"
            echo "        namespace: $namespace"
            # KCM then only accepts targets the chain says are reachable.
            if has_template_chain; then
                echo "        templateChain: $(chain_name)"
            fi
            echo "        helmOptions:"
            scenario_helm_options 10
            if [[ -n "$dep" ]]; then
                # KCM waits for the dependency before starting this one.
                echo "        dependsOn:"
                echo "          - name: $dep"
                echo "            namespace: $(service_field "$dep" namespace)"
            fi
        } >> "$out"

        values="$(effective_values "$name" "$mode")"
        if [[ -n "$values" ]]; then
            echo "        values: |" >> "$out"
            # shellcheck disable=SC2001 # per-line prefix, not a substring replace
            sed 's/^/          /' <<< "$values" >> "$out"
        fi
    done < <(services_rows)
}

# ── Expected failure ─────────────────────────────────────────────────────────
# An `expect:` block asserts the rollout stops rather than completes. Without
# one these return empty and the callers take the normal path.

# expect_field FIELD -- a scalar from the expect block.
expect_field() {
    FIELD="$1" yq -r '.expect[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

# expect_list FIELD -- one name per line from a list in the expect block.
expect_list() {
    FIELD="$1" yq -r '.expect[strenv(FIELD)][]? // ""' "$SERVICES_FILE"
}

# expects_failure -- true when the scenario declares a service that must fail.
expects_failure() {
    [[ -n "$(expect_field failed)" ]]
}

# repo_type REPO -- flux needs spec.type=oci for OCI registries.
repo_type() {
    [[ "$1" == oci://* ]] && echo oci || echo default
}
