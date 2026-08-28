#!/bin/bash
set -euo pipefail

# Deploy a scenario with several MultiClusterServices and check the
# dependencies between them.
#
# They are created in one apply so that creation order cannot be what sequences
# them -- only spec.dependsOn can. The run records when each MCS first gets a
# ServiceSet and when it first reports everything deployed, then compares those
# moments against expect.orderedAfterDependencies and expect.neverDeployed.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl jq
require_yq

check_scenario
is_multi_mcs || die "Scenario '$SCENARIO' declares a single MultiClusterService -- use deploy_mcs.sh"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

COUNT="$(mcs_count)"
MANIFEST="$WORKDIR/service-mcs-group.rendered.yaml"
: > "$MANIFEST"

step "Scenario $SCENARIO: rendering $COUNT MultiClusterService(s)"
for (( i = 0; i < COUNT; i++ )); do
    part="$WORKDIR/mcs-$i.yaml"
    MCS_IDX="$i" render_mcs "$part" initial
    { echo "---"; cat "$part"; } >> "$MANIFEST"
    deps="$(mcs_depends_on "$i" | tr '\n' ' ')"
    log "$(mcs_object_name "$i")${deps:+  depends on: $deps}"
done
cat "$MANIFEST"

step "Creating them together"
kube apply -f "$MANIFEST"

serviceset_of() { # serviceset_of MCS_OBJECT_NAME
    kube get serviceset -n "$NAMESPACE" \
        -o jsonpath="{.items[?(@.spec.multiClusterService==\"$1\")].metadata.name}" 2>/dev/null || true
}

# ── Watch ────────────────────────────────────────────────────────────────────
declare -A SS_AT DEPLOYED_AT
NEVER="$(expect_list neverDeployed | tr '\n' ' ')"
GRACE="$(expect_field graceSeconds)"
if [[ -n "${NEVER// /}" ]]; then
    LIMIT="${GRACE:-180}"
    step "Watching for ${LIMIT}s -- expecting '${NEVER% }' to stay unrolled"
else
    LIMIT="$MCS_TIMEOUT"
    step "Watching until every MultiClusterService is deployed"
fi

elapsed=0
while (( elapsed < LIMIT )); do
    all_done=true
    for (( i = 0; i < COUNT; i++ )); do
        key="$(mcs_key "$i")"
        ss="$(serviceset_of "$(mcs_object_name "$i")")"
        if [[ -n "$ss" ]]; then
            [[ -n "${SS_AT[$key]:-}" ]] || { SS_AT[$key]=$elapsed; log "── ${elapsed}s  $key: ServiceSet $ss appeared"; }
            if [[ -z "${DEPLOYED_AT[$key]:-}" ]] \
               && [[ "$(kube get serviceset "$ss" -n "$NAMESPACE" -o jsonpath='{.status.deployed}' 2>/dev/null)" == "true" ]]; then
                DEPLOYED_AT[$key]=$elapsed
                log "── ${elapsed}s  $key: all services deployed"
            fi
        fi
        [[ -n "${DEPLOYED_AT[$key]:-}" ]] || all_done=false
    done

    # A neverDeployed run has to sit out the window whatever happens.
    if [[ -z "${NEVER// /}" ]] && [[ "$all_done" == "true" ]]; then break; fi

    if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
        warn "Still waiting after ${elapsed}s -- diagnostics:"
        kcm_errors 5m >&2
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done

# ── Nothing behind a broken dependency ───────────────────────────────────────
for key in $NEVER; do
    if [[ -n "${SS_AT[$key]:-}" ]]; then
        kube get multiclusterservice -o wide >&2 || true
        die "'$key' was rolled out at ${SS_AT[$key]}s even though its dependency never became healthy"
    fi
    obj="$(mcs_object_name "$(mcs_index_of "$key")")"
    log "── $key: no ServiceSet after ${LIMIT}s, as expected"
    msg="$(kube get multiclusterservice "$obj" -o json 2>/dev/null \
        | jq -r '[.status.conditions[]?.message] | join(" ")' 2>/dev/null || true)"
    [[ -n "$msg" ]] && log "   status: $msg"
done

# ── Order ────────────────────────────────────────────────────────────────────
while read -r key; do
    [[ -n "$key" ]] || continue
    idx="$(mcs_index_of "$key")"
    [[ -n "${SS_AT[$key]:-}" ]] \
        || die "'$key' never got a ServiceSet within ${LIMIT}s -- it should have run once its dependencies were ready"

    while read -r dep; do
        [[ -n "$dep" ]] || continue
        [[ -n "${DEPLOYED_AT[$dep]:-}" ]] \
            || die "'$dep' never reported all services deployed, so '$key' should not have started"
        if (( SS_AT[$key] < DEPLOYED_AT[$dep] )); then
            die "'$key' got its ServiceSet at ${SS_AT[$key]}s, before its dependency '$dep' was deployed at ${DEPLOYED_AT[$dep]}s"
        fi
        log "── $key started at ${SS_AT[$key]}s, after '$dep' was deployed at ${DEPLOYED_AT[$dep]}s"
    done < <(mcs_depends_on "$idx")
done < <(expect_list orderedAfterDependencies)

# ── Everything that should be up, is ─────────────────────────────────────────
if [[ -z "${NEVER// /}" ]]; then
    for (( i = 0; i < COUNT; i++ )); do
        key="$(mcs_key "$i")"
        [[ -n "${DEPLOYED_AT[$key]:-}" ]] \
            || die "'$key' never reported all services deployed within ${LIMIT}s"
    done

    if [[ "${SKIP_CHILD_API_CHECK:-false}" != "true" ]]; then
        [[ -f "$KUBECONFIG_CHILD" ]] || die "No child kubeconfig at $KUBECONFIG_CHILD"
        step "Checking the workloads in the child cluster"
        while IFS="$SERVICE_SEP" read -r name _chart _version _repo namespace _dep waitfor; do
            [[ -n "$name" ]] || continue
            wait_release "$name" "$namespace" "$MCS_TIMEOUT" \
                || die "Service '$name' has no deployed helm release in the child cluster"
            [[ -n "$waitfor" ]] || continue
            KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE="$namespace" \
                WAIT_FOR_PODS="$waitfor" "$SCRIPTS_DIR/wait_for_deployment.sh"
        done < <(all_services_rows)
    fi
fi

kube get multiclusterservice
ok "MultiClusterService dependencies behaved as the scenario expects"
