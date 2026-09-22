#!/bin/bash
# Remove one k0rdent test cluster: the containers, its kubeconfig and its
# build state. Best-effort, so it is safe to run twice or from a trap.
#
#   export KCM=1.12.0-rc.3            # required: which cluster
#   ./scripts/remove_k0rdent.sh
#
#   ./scripts/remove_k0rdent.sh 1     # or: the # column of
#                                     # ./scripts/get_k0rdent_clusters.sh
set -uo pipefail

LIB="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# An index picks the environment out of the listing, so removing one does not
# mean copying its name back out of the report. Resolved before common.sh is
# sourced, because every name this script works with is derived from KCM at that
# moment - and exported, so a second pass would inherit the wrong ones rather
# than recompute them.
#
# The listing comes from a subshell for the same reason: it needs common.sh, and
# sourcing it here with no KCM is what would poison the environment.
if (( $# )); then
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || {
        echo "❌ Not an index: '$1'. Pass the # of a cluster in ./scripts/get_k0rdent_clusters.sh, or set KCM." >&2
        exit 1
    }

    # One line per environment: its KCM and the mode that built it. The mode
    # travels with the name because release refuses a KCM that is not a chart
    # version, so a source environment picked off the listing would otherwise be
    # turned away for the shape of its name.
    mapfile -t rows < <(KCM='' bash -s -- "$LIB" <<'RESOLVE'
source "$1"
require_cmd docker
while IFS=$'\t' read -r id _; do
    printf '%s\t%s\n' "$id" "$(built_field KCM_MODE "$WORKDIR/k0rdent-$id/kcm-build.env")"
done < <(k0rdent_clusters)
RESOLVE
    )

    (( ${#rows[@]} )) || {
        echo "❌ No k0rdent cluster exists, so there is no #$1 to remove." >&2
        exit 1
    }
    (( $1 <= ${#rows[@]} )) || {
        echo "❌ No #$1: there $( (( ${#rows[@]} == 1 )) && echo "is 1 cluster" || echo "are ${#rows[@]} clusters" ). See ./scripts/get_k0rdent_clusters.sh" >&2
        exit 1
    }

    row="${rows[$1 - 1]}"
    KCM="${row%%$'\t'*}"
    KCM_MODE="${row#*$'\t'}"
    # A cluster that never got as far as a build leaves the name to say it: only
    # a checkout can be called something that is not a version.
    if [[ -z "$KCM_MODE" ]]; then
        KCM_MODE=source
        [[ "$KCM" == [0-9]* ]] && KCM_MODE=release
    fi
    export KCM KCM_MODE
fi

# shellcheck source=scripts/lib/common.sh
source "$LIB"

# Not require_kcm: this script can also be told which one by position, and what
# exists answers "which one?" better than a description of KCM does.
if [[ -z "$KCM" ]]; then
    available=""
    if command -v docker >/dev/null 2>&1; then
        available="$(k0rdent_clusters | cut -f1 | nl -ba -w4 -s'  ')"
    fi
    die "Which cluster? Name it with KCM, or pass its # from ./scripts/get_k0rdent_clusters.sh:
  KCM=1.12.0-rc.3 ./scripts/remove_k0rdent.sh
  ./scripts/remove_k0rdent.sh 1${available:+

$available}"
fi

step "Removing k0rdent $KCM"

if command -v docker >/dev/null 2>&1; then
    for container in "$MGMT_CLUSTER_NAME" "$REGISTRY_NAME"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
            log "Removing container '$container'"
            docker rm -vf "$container" >/dev/null 2>&1
        fi
    done

    # Only remove the network if we are the last user; kind shares it.
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        attached="$(docker network inspect "$DOCKER_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' | tr -d ' ')"
        if [[ -z "$attached" ]]; then
            log "Removing docker network '$DOCKER_NETWORK'"
            docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1
        else
            log "Keeping network '$DOCKER_NETWORK' (still in use)"
        fi
    fi
fi

rm -f "$KUBECONFIG_NAMED" "$KUBECONFIG_NAMED.bak"
# Only if it is this cluster's: another environment may be the current one.
if [[ -L "$KUBECONFIG_MGMT" && ! -e "$KUBECONFIG_MGMT" ]]; then
    rm -f "$KUBECONFIG_MGMT"
fi

if [[ "${KEEP_WORKDIR:-false}" == "true" ]]; then
    log "Keeping $ENVDIR (KEEP_WORKDIR=true)"
else
    # The KCM checkout is the expensive part -- re-cloning costs minutes -- so
    # source mode keeps it and drops only the generated state. Only when it is
    # there: an environment that never got that far would otherwise leave an
    # empty directory behind, and the listing would keep reporting it.
    if [[ "$KCM_MODE" == "source" && -d "$ENVDIR/kcm" ]]; then
        rm -f "$ENVDIR"/*.yaml "$ENVDIR"/*.env 2>/dev/null
        log "Removed generated manifests from $ENVDIR (KCM checkout kept)"
    else
        rm -rf "$ENVDIR"
    fi
fi

ok "k0rdent $KCM removed"

# Said here rather than only in the usage comment: this is the moment the index
# form is useful, and what is left over is what it would select next.
if command -v docker >/dev/null 2>&1 && (( $(k0rdent_clusters | wc -l) )); then
    log "Remove another by its # in ./scripts/get_k0rdent_clusters.sh:  ./scripts/remove_k0rdent.sh <#>"
fi
