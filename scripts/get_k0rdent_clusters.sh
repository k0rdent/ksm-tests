#!/bin/bash
set -euo pipefail

# Every k0rdent test cluster on this machine, and which one ./kcfg_k0rdent
# points at. Deliberately ignores $KCM: the question it answers is "what do I
# have?", which the caller cannot express as a selection.
#
#   ./scripts/get_k0rdent_clusters.sh

# Cleared before sourcing so an invalid KCM in the environment cannot stop the
# report, and so no cluster looks selected.
KCM=''
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

PREFIX="k0rdent-"

# Containers first, then build directories: a cluster can have either without
# the other -- a removed container leaves the directory behind, and a
# hand-deleted directory leaves the container.
declare -A SEEN=()
while read -r name status; do
    [[ -n "$name" ]] || continue
    SEEN["${name#"$PREFIX"}"]="$status"
done < <(docker ps -a --filter "name=^$PREFIX" --format '{{.Names}}\t{{.Status}}' 2>/dev/null)

for dir in "$WORKDIR/$PREFIX"*; do
    [[ -d "$dir" ]] || continue
    key="$(basename "$dir")"
    key="${key#"$PREFIX"}"
    # A directory with no KCM in its name is left over from a run that had
    # none. Bash rejects the empty subscript anyway.
    [[ -n "$key" ]] || continue
    [[ -v "SEEN[$key]" ]] || SEEN["$key"]=""
done

(( ${#SEEN[@]} )) || {
    ok "No k0rdent cluster exists. Build one with KCM=1.11.0 ./scripts/deploy_k0rdent.sh"
    exit 0
}

# Which one the scenario scripts would talk to.
current=""
if [[ -L "$KUBECONFIG_MGMT" ]]; then
    current="$(basename "$(readlink "$KUBECONFIG_MGMT")")"
    current="${current#kcfg_k0rdent_}"
fi

printf '  %-20s %-18s %-8s %s\n' "KCM" "CLUSTER" "CURRENT" "BUILD"
for kcm in $(printf '%s\n' "${!SEEN[@]}" | sort); do
    env_file="$WORKDIR/$PREFIX$kcm/kcm-build.env"
    build="not installed"
    if [[ -f "$env_file" ]]; then
        version="$(built_field KCM_CHART_VERSION "$env_file")"
        commit="$(built_field KCM_COMMIT "$env_file")"
        date="$(built_field KCM_COMMIT_DATE "$env_file")"
        mode="$(built_field KCM_MODE "$env_file")"
        build="${mode:+$mode }${version:-?}"
        [[ -n "$commit" ]] && build="$build ($commit${date:+, $date})"
    fi
    status="${SEEN[$kcm]:-gone}"
    printf '  %-20s %-18s %-8s %s\n' \
        "$kcm" "${status:0:18}" "$([[ "$kcm" == "$current" ]] && echo '*' || echo '')" "$build"
done

echo
if [[ -n "$current" ]]; then
    log "Scenarios run against k0rdent-$current (./kcfg_k0rdent)."
else
    warn "./kcfg_k0rdent points at no cluster -- scenarios have nothing to run against."
fi
log "Switch:  ln -sfn kcfg_k0rdent_<KCM> kcfg_k0rdent"
log "Remove:  KCM=<KCM> ./scripts/remove_k0rdent.sh"
