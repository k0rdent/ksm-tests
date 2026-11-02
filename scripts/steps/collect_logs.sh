#!/usr/bin/env bash
# Dump diagnostics into $LOG_DIR. No `set -e`: one missing resource must not
# cost us the rest of the dump.
set -uo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

mkdir -p "$LOG_DIR"

step "Collecting diagnostics into $LOG_DIR"

dump() { # dump FILENAME COMMAND...
    local file="$LOG_DIR/$1"; shift
    echo "\$ $*" > "$file"
    "$@" >> "$file" 2>&1
    log "$1"
}

# ── Host / docker ────────────────────────────────────────────────────────────
dump docker-ps.txt docker ps -a
dump docker-networks.txt docker network ls
dump disk-usage.txt df -h

# A scenario run has no KCM -- it only knows ./kcfg_k0rdent -- so read the
# cluster back off the link rather than dropping the container logs.
if [[ -z "$KCM" && -L "$KUBECONFIG_MGMT" ]]; then
    MGMT_CLUSTER_NAME="k0rdent-$(basename "$(readlink "$KUBECONFIG_MGMT")" | sed 's/^kcfg_k0rdent_//')"
fi

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "$MGMT_CLUSTER_NAME"; then
    dump k0s-status.txt docker exec "$MGMT_CLUSTER_NAME" k0s status
    dump mgmt-container.log docker logs --tail 500 "$MGMT_CLUSTER_NAME"
fi

if [[ ! -f "$KUBECONFIG_MGMT" ]]; then
    warn "No management kubeconfig at $KUBECONFIG_MGMT -- stopping here"
    exit 0
fi
export KUBECONFIG="$KUBECONFIG_MGMT"

# ── Cluster-wide state ───────────────────────────────────────────────────────
dump nodes.txt kube get nodes -o wide
dump all-pods.txt kube get pods -A -o wide
dump events.txt kube get events -A --sort-by=.lastTimestamp
dump storageclasses.txt kube get storageclass
dump pvc.txt kube get pvc -A

# ── KCM objects ──────────────────────────────────────────────────────────────
dump management.yaml kube get management -o yaml
dump releases.yaml kube get releases -o yaml
dump providertemplates.txt kube get providertemplates
dump clustertemplates.txt kube get clustertemplates -A
dump clusterdeployments.yaml kube get clusterdeployments -A -o yaml
dump credentials.txt kube get credentials -A
dump servicetemplates.txt kube get servicetemplates -A
dump multiclusterservices.yaml kube get multiclusterservices -o yaml
dump servicesets.yaml kube get servicesets -A -o yaml

# ── Flux / CAPI ──────────────────────────────────────────────────────────────
dump helmreleases.txt kube get helmreleases -A
dump helmrepositories.yaml kube get helmrepositories -A -o yaml
dump helmcharts.txt kube get helmcharts -A
dump capi-clusters.txt kube get clusters -A -o wide
dump capi-machines.txt kube get machines -A -o wide
dump sveltosclusters.txt kube get sveltosclusters -A -o wide

# ── Controller logs ──────────────────────────────────────────────────────────
for ns in "$NAMESPACE" projectsveltos; do
    kube get namespace "$ns" >/dev/null 2>&1 || continue
    while read -r pod; do
        [[ -n "$pod" ]] || continue
        safe="${pod//\//-}"
        dump "logs-$ns-$safe.log" kube logs -n "$ns" "$pod" --all-containers --tail 2000
    done < <(kube get pods -n "$ns" -o name 2>/dev/null)
done

# ── Child cluster ────────────────────────────────────────────────────────────
# Under self-management the services land in this same cluster and the dumps
# above already cover them. Adopted and provisioned clusters are a separate
# machine, and when that machine is what broke -- a control plane too starved
# to finish a TLS handshake, say -- this is the only place it shows.
#
# Bounded from the outside: the cluster being unreachable is the case we are
# collecting for, and kubectl's own --request-timeout does not cover the dial,
# so against a black hole it runs for 100s rather than the 20s it was asked
# for. `timeout` bounds it whichever phase stalls.
if [[ "$KUBECONFIG_CHILD" != "$KUBECONFIG_MGMT" && -f "$KUBECONFIG_CHILD" ]]; then
    child() { timeout 30 kubectl --kubeconfig "$KUBECONFIG_CHILD" --request-timeout=25s "$@"; }

    dump child-nodes.txt child get nodes -o wide
    # Conditions and allocated resources: whether it ran out of memory, disk
    # or room to schedule, which `get nodes` alone will not say.
    dump child-nodes-describe.txt child describe nodes
    dump child-pods.txt child get pods -A -o wide
    dump child-events.txt child get events -A --sort-by=.lastTimestamp
    # Best effort -- the child may have no metrics-server.
    dump child-top-nodes.txt child top nodes
    dump child-top-pods.txt child top pods -A
else
    log "No separate child cluster to dump"
fi

ok "Diagnostics written to $LOG_DIR"
