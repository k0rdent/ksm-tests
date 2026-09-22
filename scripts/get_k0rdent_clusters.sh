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

mapfile -t CLUSTERS < <(k0rdent_clusters)

(( ${#CLUSTERS[@]} )) || {
    ok "No k0rdent cluster exists. Build one with KCM=1.12.0-rc.3 ./scripts/deploy_k0rdent.sh"
    exit 0
}

# Which one the scenario scripts would talk to.
current=""
if [[ -L "$KUBECONFIG_MGMT" ]]; then
    current="$(basename "$(readlink "$KUBECONFIG_MGMT")")"
    current="${current#kcfg_k0rdent_}"
fi

# The number is what `./scripts/remove_k0rdent.sh <N>` takes, so it is printed
# rather than counted by hand off the listing.
printf '  %-3s %-20s %-18s %-8s %s\n' "#" "KCM" "CLUSTER" "CURRENT" "BUILD"
index=0
for entry in "${CLUSTERS[@]}"; do
    index=$((index + 1))
    kcm="${entry%%$'\t'*}"
    status="${entry#*$'\t'}"
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
    printf '  %-3s %-20s %-18s %-8s %s\n' \
        "$index" "$kcm" "${status:-gone}" \
        "$([[ "$kcm" == "$current" ]] && echo '*' || echo '')" "$build"
done

echo
if [[ -n "$current" ]]; then
    log "Scenarios run against k0rdent-$current (./kcfg_k0rdent)."
else
    warn "./kcfg_k0rdent points at no cluster -- scenarios have nothing to run against."
fi
log "Switch:  ln -sfn kcfg_k0rdent_<KCM> kcfg_k0rdent"
log "Remove:  KCM=<KCM> ./scripts/remove_k0rdent.sh   (or ./scripts/remove_k0rdent.sh <#>)"
