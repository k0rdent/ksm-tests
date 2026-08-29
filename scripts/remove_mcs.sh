#!/bin/bash
set -euo pipefail

# Delete the MultiClusterService and verify the services are really gone from
# the child cluster, not just from the management cluster's objects.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl helm jq
require_yq

check_scenario

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

# remove_one MCS_OBJECT_NAME -- delete it and wait for its ServiceSet to go.
remove_one() {
    local mcs="$1" sset elapsed=0

    if ! resource_exists MultiClusterService "$mcs"; then
        log "MultiClusterService '$mcs' does not exist -- nothing to remove"
    else
        step "Scenario $SCENARIO: deleting MultiClusterService '$mcs'"
        kube delete multiclusterservice "$mcs" --wait=false
        wait_for_absence MultiClusterService "$mcs" "" "$MCS_TIMEOUT" 5
    fi

    step "Checking the ServiceSet of '$mcs' is gone"
    # Only the MCS-owned one: the ClusterDeployment keeps a ServiceSet of its
    # own for as long as the cluster exists.
    while (( elapsed < MCS_TIMEOUT )); do
        sset="$(kube get serviceset -n "$NAMESPACE" \
            -o jsonpath="{.items[?(@.spec.multiClusterService==\"$mcs\")].metadata.name}" 2>/dev/null || true)"
        [[ -z "$sset" ]] && break
        if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
            warn "ServiceSet '$sset' still present after ${elapsed}s -- diagnostics:"
            { describe_stuck ServiceSet "$sset" "$NAMESPACE"; kcm_errors 5m; } >&2
        elif (( elapsed % 30 == 0 )); then
            log "⏳ ServiceSet '$sset' still present (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    if [[ -n "${sset:-}" ]]; then
        { describe_stuck ServiceSet "$sset" "$NAMESPACE"; kcm_errors 20m; } >&2
        die "ServiceSet '$sset' survived the MultiClusterService"
    fi
    ok "No ServiceSet left for '$mcs'"
}

# Dependants first: deleting a dependency out from under one that is still
# running is not what the scenario set up.
for (( i = $(mcs_count) - 1; i >= 0; i-- )); do
    remove_one "$(mcs_object_name "$i")"
done

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not verifying removal in the child cluster"
else
    [[ -f "$KUBECONFIG_CHILD" ]] || die "No child kubeconfig at $KUBECONFIG_CHILD"

    # The helm release, not just the workloads: a release record can survive a
    # removal that emptied the namespace, and the next scenario on the same
    # cluster then fails to install over it. Counting workloads alone reported
    # success while kserve-resources was still deployed.
    step "Checking the helm releases are gone from the child cluster"
    while IFS="$SERVICE_SEP" read -r name _chart _version _repo ns _dep _wait; do
        [[ -n "$name" ]] || continue
        elapsed=0
        while (( elapsed < MCS_TIMEOUT )); do
            info="$(release_info "$name" "$ns")"
            [[ -z "$info" ]] && break
            if (( elapsed % 30 == 0 )); then
                log "⏳ release '$name' still in '$ns': $info (${elapsed}s)"
            fi
            sleep 5
            elapsed=$(( elapsed + 5 ))
        done
        if [[ -n "${info:-}" ]]; then
            warn "Helm release '$name' survived the removal: $info"
            helm_child list --deployed --failed --pending --uninstalled --superseded \
                -n "$ns" >&2 || true
            kcm_errors 20m >&2 || true
            exit 1
        fi
        log "✅ '$name' has no release left in '$ns'"
    done < <(all_services_rows)

    step "Checking the workloads are gone from the child cluster"
    while read -r ns; do
        [[ -n "$ns" ]] || continue
        # The namespace itself may linger; what matters is that no workload does.
        remaining="$(kube_child get deployments,daemonsets,statefulsets \
            -n "$ns" -o name 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$remaining" != "0" ]]; then
            warn "Workloads still present in '$ns' after removal:"
            kube_child get all -n "$ns" >&2 || true
            exit 1
        fi
        log "✅ '$ns' has no workloads left"
    done < <(all_service_namespaces)
fi

step "Removing the ServiceTemplates"
while IFS="$SERVICE_SEP" read -r name chart version _repo _ns _dep _wait; do
    [[ -n "$name" ]] || continue
    kube delete servicetemplate "$(template_name_for "$chart" "$version")" \
        -n "$NAMESPACE" --ignore-not-found
    # An upgrade scenario also left a template for the newer version behind.
    upgraded="$(effective_version "$name" upgraded)"
    if [[ "$upgraded" != "$version" ]]; then
        kube delete servicetemplate "$(template_name_for "$chart" "$upgraded")" \
            -n "$NAMESPACE" --ignore-not-found
    fi
    kube delete helmrepository "$name" -n "$NAMESPACE" --ignore-not-found
done < <(all_services_rows)

if has_template_chain; then
    # Chains are cluster-scoped leftovers otherwise: running another scenario
    # on the same cluster would find a stale one still lying around.
    kube delete servicetemplatechain "$(chain_name)" -n "$NAMESPACE" --ignore-not-found
fi

ok "Service lifecycle completed"
