#!/bin/bash
set -euo pipefail

# Walk a scenario's `upgrade.steps` and check each one against what the
# ServiceTemplateChain allows.
#
# A step either lands or is refused:
#
#   expect: applied   -- the helm release ends on that chart version
#   expect: rejected  -- the release stays where it was for the whole grace
#                        window; KCM keeps the stored version rather than
#                        erroring, so "nothing changed" is the observable
#
# A step may also declare viaVersions: versions the release must have passed
# through on the way. Helm history records every revision, so this is checked
# after the fact rather than by watching for a moment that may be brief.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl helm jq
require_yq

check_scenario

STEPS="$(upgrade_steps)"
if (( STEPS == 0 )); then
    log "Scenario $SCENARIO has no upgrade steps -- nothing to do"
    exit 0
fi

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- the chain checks read the child cluster, skipping"
    exit 0
fi
[[ -f "$KUBECONFIG_CHILD" ]] || die "No child kubeconfig at $KUBECONFIG_CHILD"

SVC="$(chain_service)"
CHART="$(service_field "$SVC" chart)"
NS="$(service_field "$SVC" namespace)"
GRACE="$(yq -r '.upgrade.graceSeconds // ""' "$SERVICES_FILE")"
GRACE="${GRACE:-120}"

chart_version() { echo "${1#"$CHART"-}"; }

current_version() {
    chart_version "$(cut -d'|' -f2 <<< "$(release_info "$SVC" "$NS")")"
}

# history_versions -- every chart version this release has ever been on.
history_versions() {
    helm_child history "$SVC" -n "$NS" -o json 2>/dev/null \
        | jq -r '.[].chart' 2>/dev/null | while read -r c; do chart_version "$c"; done
}

if has_template_chain; then
    log "Chain '$(chain_name)' allows:"
    while read -r v; do
        [[ -n "$v" ]] || continue
        log "   $v -> $(chain_upgrades_for "$v" | tr '\n' ' ' | sed 's/ $//' || true)"
    done < <(chain_versions)
else
    log "No ServiceTemplateChain: nothing constrains the upgrade"
fi

for (( i = 0; i < STEPS; i++ )); do
    target="$(upgrade_step_field "$i" version)"
    want="$(upgrade_step_field "$i" expect)"
    before="$(current_version)"
    [[ -n "$before" ]] || die "'$SVC' has no helm release in '$NS' to upgrade"

    step "Step $((i + 1))/$STEPS: $before -> $target (expecting it to be $want)"

    MANIFEST="$WORKDIR/service-mcs.step-$i.yaml"
    UPGRADE_TO="$target" render_mcs_at_version "$MANIFEST"
    kube apply -f "$MANIFEST"

    elapsed=0
    settled=false
    while (( elapsed < MCS_TIMEOUT )); do
        now="$(current_version)"
        if [[ "$want" == "applied" && "$now" == "$target" ]]; then
            settled=true; break
        fi
        if [[ "$want" == "rejected" ]]; then
            # A refusal is the absence of a change, so it can only be
            # established by watching for a while.
            [[ "$now" != "$before" ]] && {
                { helm_child history "$SVC" -n "$NS" 2>&1 | tail -5; } >&2
                die "'$SVC' moved $before -> $now, but the chain does not allow $target"
            }
            (( elapsed >= GRACE )) && { settled=true; break; }
        fi
        (( elapsed % 30 == 0 )) && log "⏳ '$SVC' is on $now (${elapsed}s)"
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    if [[ "$settled" != "true" ]]; then
        { helm_child history "$SVC" -n "$NS" 2>&1 | tail -6
          kube get serviceset -n "$NAMESPACE" -o yaml | head -60
          kcm_errors 10m; } >&2
        die "'$SVC' never reached $target -- it is on $(current_version)"
    fi

    if [[ "$want" == "applied" ]]; then
        ok "'$SVC' upgraded to $target"
        while read -r via; do
            [[ -n "$via" ]] || continue
            history_versions | grep -qx "$via" \
                || { helm_child history "$SVC" -n "$NS" 2>&1 | tail -8 >&2
                     die "'$SVC' reached $target without ever being on $via -- the chain says it must step through it"; }
            log "── passed through $via on the way"
        done < <(upgrade_step_list "$i" viaVersions)
    else
        ok "'$SVC' stayed on $before for ${GRACE}s, as the chain requires"
    fi
done

step "Release history"
helm_child history "$SVC" -n "$NS" 2>&1 | tail -8
ok "Every upgrade step behaved as the chain says it should"
