#!/bin/bash
set -euo pipefail

# Upgrade some services of a deployed MultiClusterService and check what moved.
# A no-op without an `upgrade:` block, so it can sit in the pipeline always.
#
#   rolledOut    -- reaches the new chart version
#   untouched    -- keeps its version and its pods
#   rolledBackTo -- the failed upgrade is undone and the release ends healthy

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl helm jq
require_yq

check_scenario

if ! has_upgrade; then
    log "Scenario $SCENARIO has no upgrade block -- nothing to do"
    exit 0
fi

# Chain scenarios are walked by upgrade_chain.sh instead.
if (( $(upgrade_steps) > 0 )); then
    log "Scenario $SCENARIO upgrades along a chain -- handled by upgrade_chain.sh"
    exit 0
fi

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- the upgrade checks read the child cluster, skipping"
    exit 0
fi
[[ -f "$KUBECONFIG_CHILD" ]] \
    || die "No child kubeconfig at $KUBECONFIG_CHILD. Run ./scripts/check_child_cluster.sh first."

# ── Snapshot ─────────────────────────────────────────────────────────────────
# Every later claim is relative to this.
step "Scenario $SCENARIO: recording the state before the upgrade"
declare -A BEFORE_REL BEFORE_PODS
while IFS="$SERVICE_SEP" read -r name _chart _version _repo namespace _dep _wait; do
    [[ -n "$name" ]] || continue
    BEFORE_REL["$name"]="$(release_info "$name" "$namespace")"
    BEFORE_PODS["$name"]="$(pod_uids "$namespace")"
    log "── $name: ${BEFORE_REL[$name]:-<no release>}"
done < <(services_rows)

# ── Apply the upgrade ────────────────────────────────────────────────────────
step "Installing ServiceTemplates for the upgraded versions"
TEMPLATES="$WORKDIR/service-templates.upgraded.yaml"
render_templates "$TEMPLATES" upgraded
kube apply -f "$TEMPLATES"

while read -r name; do
    [[ -n "$name" ]] || continue
    chart="$(service_field "$name" chart)"
    version="$(effective_version "$name" upgraded)"
    wait_for_valid ServiceTemplate "$(template_name_for "$chart" "$version")" \
        "$NAMESPACE" "$TEMPLATES_TIMEOUT"
done < <(upgrade_names)

step "Patching the MultiClusterService"
MANIFEST="$WORKDIR/service-mcs.upgraded.yaml"
render_mcs "$MANIFEST" upgraded
cat "$MANIFEST"
kube apply -f "$MANIFEST"

SERVICE_SET="$(kube get serviceset -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.multiClusterService==\"$MCS_NAME\")].metadata.name}" 2>/dev/null || true)"
[[ -n "$SERVICE_SET" ]] || die "No ServiceSet for MultiClusterService '$MCS_NAME'"

sset_json() {
    kube get serviceset "$SERVICE_SET" -n "$NAMESPACE" -o json 2>/dev/null || echo '{}'
}
state_of() {
    jq -r --arg n "$1" '.status.services[]? | select(.name == $n) | .state // ""' <<< "$2"
}
dump_states() {
    jq -r '.status.services[]? | "    \(.name): \(.state)\(if .failureMessage != "" and .failureMessage != null then " -- " + .failureMessage else "" end)"' <<< "$1"
}

# chart_version -- chart names contain dashes, so strip the known prefix rather
# than splitting on the last one.
chart_version() { # chart_version RELEASE_CHART CHART_NAME
    echo "${1#"$2"-}"
}

EXPECT_FAILED="$(upgrade_expect_field failed)"
ROLLED_BACK_TO="$(upgrade_expect_field rolledBackTo)"

# ── Wait for the upgrade to settle ───────────────────────────────────────────
# Watching the helm release, not the ServiceSet: the ServiceSet has been seen
# reporting Deployed at a version whose release no longer existed.
settled=false
elapsed=0

if [[ -n "$ROLLED_BACK_TO" ]]; then
    watch_svc="$EXPECT_FAILED"
    step "Waiting for the atomic upgrade of '$watch_svc' to settle"
    ns="$(service_field "$watch_svc" namespace)"
    chart="$(service_field "$watch_svc" chart)"
    before_rev="$(cut -d'|' -f1 <<< "${BEFORE_REL[$watch_svc]}")"
    # Helm briefly reports failed before undoing the upgrade, so only a
    # sustained reading proves anything.
    absent_for=0
    broken_for=0
    GRACE_TERMINAL="${GRACE_TERMINAL:-90}"

    # Two terminal bad endings: the release disappears, or it returns on the
    # old chart but failed. Waiting out the timeout only delays the verdict.
    rollback_diag() {
        { echo "── helm history $watch_svc -n $ns"
          helm_child history "$watch_svc" -n "$ns" 2>&1 | tail -6
          dump_states "$(sset_json)"
          kcm_errors 10m; } >&2
    }

    while (( elapsed < MCS_TIMEOUT )); do
        info="$(release_info "$watch_svc" "$ns")"
        if [[ -z "$info" ]]; then
            broken_for=0
            absent_for=$(( absent_for + 5 ))
            if (( absent_for >= GRACE_TERMINAL )); then
                rollback_diag
                die "'$watch_svc' was removed instead of rolled back: no helm release in '$ns' for ${absent_for}s, though a healthy revision $before_rev existed before the upgrade"
            fi
        else
            absent_for=0
            got="$(chart_version "$(cut -d'|' -f2 <<< "$info")" "$chart")"
            status="$(cut -d'|' -f3 <<< "$info")"
            rev="$(cut -d'|' -f1 <<< "$info")"
            if [[ "$got" == "$ROLLED_BACK_TO" && "$status" == "deployed" ]] \
               && (( rev > before_rev )); then
                settled=true; break
            fi
            if [[ "$status" == "failed" ]]; then
                broken_for=$(( broken_for + 5 ))
                if (( broken_for >= GRACE_TERMINAL )); then
                    rollback_diag
                    die "'$watch_svc' did not roll back to a healthy state: the release is on $got but 'failed' for ${broken_for}s (revision $before_rev -> $rev)"
                fi
            else
                broken_for=0
            fi
        fi
        (( elapsed % 30 == 0 )) && log "⏳ '$watch_svc' release: ${info:-<absent>} (${elapsed}s)"
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
else
    watch_svc="$(upgrade_expect_list rolledOut | head -1)"
    step "Waiting for '$watch_svc' to reach the upgraded version"
    ns="$(service_field "$watch_svc" namespace)"
    chart="$(service_field "$watch_svc" chart)"
    want="$(effective_version "$watch_svc" upgraded)"

    # The status matters as much as the version: helm writes the new revision
    # with status pending-upgrade the moment the upgrade starts, so waiting on
    # the version alone lets this through while the upgrade is still running,
    # and the checks below then see pending-upgrade.
    while (( elapsed < MCS_TIMEOUT )); do
        json="$(sset_json)"
        info="$(release_info "$watch_svc" "$ns")"
        got="$(chart_version "$(cut -d'|' -f2 <<< "$info")" "$chart")"
        status="$(cut -d'|' -f3 <<< "$info")"
        if [[ "$(state_of "$watch_svc" "$json")" == "Deployed" \
              && "$got" == "$want" && "$status" == "deployed" ]]; then
            settled=true; break
        fi
        if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
            warn "'$watch_svc' is at '${got:-<absent>}' (${status:-<absent>}) after ${elapsed}s -- diagnostics:"
            { dump_states "$json"; kcm_errors 5m; } >&2
        elif (( elapsed % 30 == 0 )); then
            log "⏳ '$watch_svc' is at '${got:-<absent>}' (${status:-<absent>}), want $want (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
fi

if [[ "$settled" != "true" ]]; then
    { dump_states "$(sset_json)"; describe_stuck ServiceSet "$SERVICE_SET" "$NAMESPACE"
      kcm_errors 20m; } >&2
    die "'$watch_svc' never settled into the state the scenario expects"
fi
ok "'$watch_svc' settled"

# ── What must have moved ─────────────────────────────────────────────────────
json="$(sset_json)"

while read -r name; do
    [[ -n "$name" ]] || continue
    ns="$(service_field "$name" namespace)"
    chart="$(service_field "$name" chart)"
    want="$(effective_version "$name" upgraded)"
    info="$(release_info "$name" "$ns")"
    got="$(chart_version "$(cut -d'|' -f2 <<< "$info")" "$chart")"
    [[ "$got" == "$want" ]] \
        || die "'$name' should have been upgraded to $want but the release is on '$got'"
    [[ "$(cut -d'|' -f3 <<< "$info")" == "deployed" ]] \
        || die "'$name' upgraded to $want but the release is '$(cut -d'|' -f3 <<< "$info")'"
    log "── rolled out: $name -> $want (revision $(cut -d'|' -f1 <<< "$info"))"
done < <(upgrade_expect_list rolledOut)

# ── What must have been rolled back ──────────────────────────────────────────
if [[ -n "$ROLLED_BACK_TO" ]]; then
    name="$EXPECT_FAILED"
    ns="$(service_field "$name" namespace)"
    chart="$(service_field "$name" chart)"
    info="$(release_info "$name" "$ns")"
    got="$(chart_version "$(cut -d'|' -f2 <<< "$info")" "$chart")"
    status="$(cut -d'|' -f3 <<< "$info")"

    [[ "$got" == "$ROLLED_BACK_TO" ]] \
        || die "'$name' should have rolled back to $ROLLED_BACK_TO but the release is on '$got'"
    # A release left failed is not a rollback to a healthy state.
    [[ "$status" == "deployed" ]] \
        || die "'$name' rolled back to $ROLLED_BACK_TO but the release is '$status', not healthy"

    before_rev="$(cut -d'|' -f1 <<< "${BEFORE_REL[$name]}")"
    after_rev="$(cut -d'|' -f1 <<< "$info")"
    (( after_rev > before_rev )) \
        || warn "'$name' is at revision $after_rev, same as before -- the upgrade may never have been attempted"
    ok "'$name' rolled back to $ROLLED_BACK_TO and is healthy (revision $before_rev -> $after_rev)"

    waitfor="$(service_field "$name" waitForPods)"
    if [[ -n "$waitfor" ]]; then
        KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE="$ns" \
            WAIT_FOR_PODS="$waitfor" "$SCRIPTS_DIR/wait_for_deployment.sh"
    fi
fi

# ── What must not have moved ─────────────────────────────────────────────────
step "Checking the untouched services really were left alone"
while read -r name; do
    [[ -n "$name" ]] || continue
    ns="$(service_field "$name" namespace)"
    chart="$(service_field "$name" chart)"
    before="${BEFORE_REL[$name]}"
    after="$(release_info "$name" "$ns")"

    before_ver="$(chart_version "$(cut -d'|' -f2 <<< "$before")" "$chart")"
    after_ver="$(chart_version "$(cut -d'|' -f2 <<< "$after")" "$chart")"
    [[ "$before_ver" == "$after_ver" ]] \
        || die "'$name' was not upgraded but its chart moved $before_ver -> $after_ver"

    after_pods="$(pod_uids "$ns")"
    [[ "${BEFORE_PODS[$name]}" == "$after_pods" ]] \
        || { echo "before: ${BEFORE_PODS[$name]}" >&2; echo "after:  $after_pods" >&2
             die "'$name' was not upgraded but its pods were replaced"; }

    before_rev="$(cut -d'|' -f1 <<< "$before")"
    after_rev="$(cut -d'|' -f1 <<< "$after")"
    if [[ "$before_rev" != "$after_rev" ]]; then
        # Not fatal -- same pods, so nothing rolled out -- but it means helm
        # re-ran for a service the scenario never changed.
        warn "'$name' kept its pods and chart but its helm revision moved $before_rev -> $after_rev"
    fi
    log "── untouched: $name at $after_ver, $(wc -l <<< "$after_pods" | tr -d ' ') pod(s) unchanged"
done < <(upgrade_expect_list untouched)

step "Final ServiceSet state"
dump_states "$json"
ok "Upgrade behaved as the scenario expects"
