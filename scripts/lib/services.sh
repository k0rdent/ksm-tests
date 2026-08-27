#!/bin/bash
# Helpers for reading $SERVICES_FILE. Expects common.sh to be sourced first.

# ── One or several MultiClusterServices ──────────────────────────────────────
# Most scenarios declare a flat `services:` list and get one MCS. Scenarios
# about dependencies *between* MCSs declare `multiClusterServices:` instead,
# and every accessor below then reads the one selected by $MCS_IDX. Keeping the
# flat form working means the existing scenarios need no changes.

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

# SERVICE_SEP must not be whitespace: `read` with a whitespace IFS collapses
# runs of it, which silently drops empty fields and shifts every later value
# left. Optional fields like dependsOn are routinely empty.
# shellcheck disable=SC2034 # used by the scripts that source this
SERVICE_SEP='|'

# services_rows -- one line per service, SERVICE_SEP separated:
#   name|chart|version|repo|namespace|dependsOn|waitForPods
services_rows() {
    yq -r "$(mcs_root).services[] | [.name, .chart, .version, .repo, .namespace,
                          (.dependsOn // \"\"), (.waitForPods // \"\")] | join(\"|\")" "$SERVICES_FILE"
}

# all_services_rows -- every service across every MCS, for the steps that have
# to touch the whole scenario at once (templates, teardown).
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
# A scenario records the KCM variants it is known to fail on. The entry is
# deliberately narrow: it names the step and a fragment of the expected error,
# so a leg that breaks for some other reason still goes red instead of being
# swallowed by the marker.

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
# A scenario with an `upgrade:` block deploys once, changes some services, and
# then asserts what moved and what did not.

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

# scenario_atomic -- "true" when the scenario runs with helmOptions.atomic.
# It is a property of the whole scenario, not of the upgrade: the issue calls
# for atomic to be part of the provider configuration, and adding it only at
# upgrade time changes the spec in a way that makes sveltos uninstall and
# reinstall instead of upgrading, which is a different test entirely.
scenario_atomic() {
    yq -r '.helmOptions.atomic // false' "$SERVICES_FILE"
}

upgrade_expect_field() {
    FIELD="$1" yq -r '.upgrade.expect[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

upgrade_expect_list() {
    FIELD="$1" yq -r '.upgrade.expect[strenv(FIELD)][]? // ""' "$SERVICES_FILE"
}

# effective_version NAME MODE [FALLBACK] -- the chart version this service
# should be at. MODE=upgraded applies the override; anything else keeps the
# declared version.
#
# FALLBACK matters for the multi-MCS scenarios: service_field only sees the
# currently selected MCS, so a caller iterating across all of them must pass the
# version it already has from the row. Without it the lookup silently returns
# empty and the template name comes out as "traefik-".
effective_version() {
    local v
    if [[ "${2:-}" == "upgraded" ]]; then
        v="$(upgrade_field "$1" version)"
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    v="$(service_field "$1" version)"
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "${3:-}"
}

# effective_values NAME MODE -- likewise for the values block. An override
# replaces the original outright rather than merging: a merge would make it
# impossible to remove a key, and every override here is a whole block anyway.
effective_values() {
    local v
    if [[ "${2:-}" == "upgraded" ]]; then
        v="$(upgrade_field "$1" values)"
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    service_values "$1"
}

# render_templates FILE MODE -- a HelmRepository and ServiceTemplate per
# service, at its effective version. In upgraded mode the entries that did not
# change render identically, so applying the file is a no-op for them and only
# the new chart version is added.
# shellcheck disable=SC2153 # NAMESPACE is from common.sh, not a typo for $_ns
render_templates() {
    local out="$1" mode="${2:-initial}"
    : > "$out"
    local name chart version repo _ns _dep _wait tmpl
    while IFS="$SERVICE_SEP" read -r name chart version repo _ns _dep _wait; do
        [[ -n "$name" ]] || continue
        version="$(effective_version "$name" "$mode" "$version")"
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
    done < <(all_services_rows)
}

# render_mcs FILE MODE -- the MultiClusterService manifest. Shared by the
# initial deploy and the upgrade so the two cannot drift apart.
render_mcs() {
    local out="$1" mode="${2:-initial}" atomic
    atomic="$(scenario_atomic)"

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

    # An MCS-level dependsOn holds this whole MCS back until the ones it names
    # are deployed and healthy -- KCM does not even create its ServiceSet.
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
            # Atomic makes helm undo a failed upgrade instead of leaving the
            # release broken, which is the whole point of the atomic scenario.
            if [[ "$atomic" == "true" ]]; then
                echo "        helmOptions:"
                echo "          atomic: true"
            fi
            if [[ -n "$dep" ]]; then
                # KCM waits for the dependency to be deployed before starting
                # this one: kserve needs cert-manager's webhooks and its own
                # CRDs first.
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
# A scenario with an `expect:` block is asserting that the rollout stops rather
# than that it completes. Without one these all return empty and the callers
# take the normal path.

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
