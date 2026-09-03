#!/bin/bash
set -euo pipefail

# What is built right now, across every RUN_ID -- not just the one selected.
# Deliberately independent of the current KCM/RUN_ID: the question this answers
# is "what do I have?", which the caller cannot express as a selection.

# Cleared before sourcing: the caller's selection must not narrow what is
# reported, and an invalid KCM in the environment must not stop the report.
KCM=''
RUN_ID=''
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

# run_id_of NAME PREFIX -- "" for the bare name, the suffix otherwise.
run_id_of() {
    [[ "$1" == "$2" ]] && { echo ""; return; }
    echo "${1#"$2"-}"
}

# Containers first, then working directories: an environment can have either
# without the other -- a torn-down cluster leaves the workdir, and `docker rm`
# leaves nothing but it.
# Keys carry a leading @: bash rejects the empty subscript, and the default
# RUN_ID is exactly that.
declare -A SEEN=()
while read -r name status; do
    [[ -n "$name" ]] || continue
    SEEN["@$(run_id_of "$name" "kcm-mgmt")"]="$status"
done < <(docker ps -a --filter "name=^kcm-mgmt" --format '{{.Names}}\t{{.Status}}' 2>/dev/null)

for dir in "$PROJECT_ROOT"/.work "$PROJECT_ROOT"/.work-*; do
    [[ -d "$dir" ]] || continue
    key="@$(run_id_of "$(basename "$dir")" ".work")"
    [[ -v "SEEN[$key]" ]] || SEEN["$key"]=""
done

(( ${#SEEN[@]} )) || { ok "No environment is built. Start one with 'make env-up'."; exit 0; }

# field KEY FILE -- read rather than source. kcm-build.env is data; sourcing it
# would run whatever a stale or hand-edited file happens to contain. Accepts
# both the quoted form and the unquoted one older runs wrote.
field() {
    sed -n "s/^$1='\(.*\)'$/\1/p; s/^$1=\([^']*\)$/\1/p" "$2" 2>/dev/null | head -1
}

# state RUN_ID -- one line per environment.
describe() {
    local id="${1#@}" mgmt="${SEEN[$1]}" suffix="" workdir kcm="" reuse="" adopted="-"
    [[ -n "$id" ]] && suffix="-$id"
    workdir="$PROJECT_ROOT/.work$suffix"

    adopted="$(docker ps -a --filter "name=^adopted$suffix\$" --format '{{.Status}}' 2>/dev/null | head -1)"
    adopted="${adopted:--}"

    local env_file="$workdir/kcm-build.env"
    if [[ -f "$env_file" ]]; then
        local version commit date mode variant ref
        version="$(field KCM_CHART_VERSION "$env_file")"
        commit="$(field KCM_COMMIT "$env_file")"
        date="$(field KCM_COMMIT_DATE "$env_file")"
        mode="$(field KCM_MODE "$env_file")"
        variant="$(field KCM_VARIANT "$env_file")"
        ref="$(field KCM_REF "$env_file")"

        kcm="${mode:+$mode }${version:-?}"
        [[ -n "$commit" ]] && kcm="$kcm ($commit${date:+, $date})"
        # No mode recorded means the environment predates it -- guessing how to
        # reuse it would be worse than saying nothing.
        if [[ -n "$variant" ]]; then
            reuse="KCM=$variant"
        elif [[ "$mode" == "source" ]]; then
            reuse="KCM_MODE=source KCM_REF=$ref"
        elif [[ "$mode" == "release" ]]; then
            reuse="KCM_VERSION=$version"
        fi
    else
        kcm="not installed"
    fi

    printf '  %-22s %-16s %-16s %s\n' \
        "${id:-<none>}" "${mgmt:0:16}" "${adopted:0:16}" "$kcm"
    [[ -n "$reuse" && -n "$mgmt" ]] \
        && printf '  %-22s %s\n' "" "↳ make scenario RUN_ID=${id:-''} SCENARIO=<id> $reuse"
    return 0
}

step "Environments"
printf '  %-22s %-16s %-16s %s\n' "RUN_ID" "MGMT" "ADOPTED" "KCM"
for key in $(printf '%s\n' "${!SEEN[@]}" | sort); do
    [[ -n "${SEEN[$key]}" ]] || continue
    describe "$key"
done

# A workdir with no cluster is the common leftover: env-down removes the
# containers, not the directory.
stale=()
for key in $(printf '%s\n' "${!SEEN[@]}" | sort); do
    [[ -n "${SEEN[$key]}" ]] || { id="${key#@}"; stale+=("${id:-<none>}"); }
done
if (( ${#stale[@]} )); then
    step "Working directories with no cluster"
    log "${stale[*]}"
    log "Remove one with: make clean RUN_ID=<id>"
fi
