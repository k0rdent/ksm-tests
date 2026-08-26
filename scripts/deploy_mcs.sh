#!/bin/bash
set -euo pipefail

# Deploy every service in $SERVICES_FILE to the child cluster through a single
# MultiClusterService, then verify they actually landed there -- an MCS
# reporting success is not proof the workloads are running.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

require_cmd kubectl jq
require_yq

[[ -f "$SERVICES_FILE" ]] || die "No services file at $SERVICES_FILE"

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster
ensure_workdir

MANIFEST="$WORKDIR/service-mcs.rendered.yaml"

cat > "$MANIFEST" <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: MultiClusterService
metadata:
  name: $MCS_NAME
spec:
  clusterSelector:
    matchLabels:
      group: $CLD_GROUP_LABEL
  serviceSpec:
    services:
EOF

while IFS="$SERVICE_SEP" read -r name chart version _repo namespace dep _wait; do
    [[ -n "$name" ]] || continue
    {
        echo "      - template: $(template_name_for "$chart" "$version")"
        echo "        name: $name"
        echo "        namespace: $namespace"
        if [[ -n "$dep" ]]; then
            # KCM waits for the dependency to be deployed before starting this
            # one: kserve needs cert-manager's webhooks and its own CRDs first.
            echo "        dependsOn:"
            echo "          - name: $dep"
            echo "            namespace: $(service_field "$dep" namespace)"
        fi
    } >> "$MANIFEST"

    values="$(service_values "$name")"
    if [[ -n "$values" ]]; then
        echo "        values: |" >> "$MANIFEST"
        # shellcheck disable=SC2001 # per-line prefix, not a substring replace
        sed 's/^/          /' <<< "$values" >> "$MANIFEST"
    fi
done < <(services_rows)

step "Creating MultiClusterService '$MCS_NAME' (group=$CLD_GROUP_LABEL)"
cat "$MANIFEST"
kube apply -f "$MANIFEST"

step "Waiting for the ServiceSet from '$MCS_NAME'"
# KCM turns the MCS into a ServiceSet per matched cluster; if the selector is
# wrong nothing is ever created, which is the failure worth catching early.
# Filter on spec.multiClusterService, not spec.cluster: every ClusterDeployment
# already owns a ServiceSet of its own, which would match unconditionally.
elapsed=0
while (( elapsed < MCS_TIMEOUT )); do
    sset="$(kube get serviceset -n "$NAMESPACE" \
        -o jsonpath="{.items[?(@.spec.multiClusterService==\"$MCS_NAME\")].metadata.name}" 2>/dev/null || true)"
    if [[ -n "$sset" ]]; then
        log "ServiceSet: $sset"
        break
    fi
    if (( elapsed > 0 && elapsed % ${DIAG_INTERVAL:-120} == 0 )); then
        warn "No ServiceSet for '$MCS_NAME' after ${elapsed}s -- diagnostics:"
        kcm_errors 5m >&2
    elif (( elapsed % 30 == 0 )); then
        log "⏳ No ServiceSet for '$MCS_NAME' yet (${elapsed}s)"
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
done
if [[ -z "${sset:-}" ]]; then
    warn "No ServiceSet was created for '$MCS_NAME' -- check the MCS selector"
    kube get multiclusterservice "$MCS_NAME" -o yaml >&2 || true
    kube get clusterdeployment "$CLD_NAME" -n "$NAMESPACE" --show-labels >&2 || true
    kcm_errors 20m >&2 || true
    exit 1
fi

if [[ "${SKIP_CHILD_API_CHECK:-false}" == "true" ]]; then
    warn "SKIP_CHILD_API_CHECK=true -- not verifying the workloads in the child cluster"
    kube get multiclusterservice "$MCS_NAME"
    ok "MultiClusterService '$MCS_NAME' created"
    exit 0
fi

[[ -f "$KUBECONFIG_CHILD" ]] \
    || die "No child kubeconfig at $KUBECONFIG_CHILD. Run ./scripts/check_child_cluster.sh first."

step "Waiting for the workloads in the child cluster"
while IFS="$SERVICE_SEP" read -r name _chart _version _repo namespace _dep waitfor; do
    [[ -n "$name" ]] || continue
    # Services without a waitForPods only ship CRDs or config, so there is
    # nothing to wait for beyond the namespace.
    log "── $name -> namespace '$namespace'"

    elapsed=0
    while (( elapsed < MCS_TIMEOUT )); do
        kube_child get namespace "$namespace" >/dev/null 2>&1 && break
        if (( elapsed % 30 == 0 )); then
            log "⏳ Namespace '$namespace' not in the child cluster yet (${elapsed}s)"
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    if ! kube_child get namespace "$namespace" >/dev/null 2>&1; then
        { describe_stuck MultiClusterService "$MCS_NAME" ""; kcm_errors 20m; } >&2
        die "Namespace '$namespace' never appeared in the child cluster (service '$name')"
    fi

    [[ -n "$waitfor" ]] || { log "no waitForPods for '$name', namespace is enough"; continue; }

    KUBECONFIG="$KUBECONFIG_CHILD" NAMESPACE="$namespace" \
        WAIT_FOR_PODS="$waitfor" "$SCRIPTS_DIR/wait_for_deployment.sh"
done < <(services_rows)

step "Deployed workloads"
while read -r ns; do
    [[ -n "$ns" ]] || continue
    echo "── $ns"
    kube_child get pods -n "$ns" 2>/dev/null || true
done < <(service_namespaces)

kube get multiclusterservice "$MCS_NAME"
ok "All services deployed via MultiClusterService"
