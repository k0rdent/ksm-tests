#!/usr/bin/env bash
set -euo pipefail

# Apply the Management object listing only $KCM_PROVIDERS.
#
# The chart runs with createManagement=false, so no default Management (which
# would enable every provider in the Release) is ever created.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst
require_yq

RELEASE_ENV="$ENVDIR/release.env"
[[ -f "$RELEASE_ENV" ]] || die "$RELEASE_ENV not found. Run ./scripts/apply_release.sh first."
# shellcheck source=/dev/null
source "$RELEASE_ENV"
require_env RELEASE_NAME

export KUBECONFIG="$KUBECONFIG_MGMT"

# The rationale belongs in the file, not in a Kubernetes object, so the comments
# are stripped -- and a file with nothing but comments must render no config.
SVELTOS_CONFIG=""
if [[ -n "$SVELTOS_VALUES" && -f "$SVELTOS_VALUES" ]]; then
    SVELTOS_CONFIG="$(yq -P '... comments="" | select(. != null)' "$SVELTOS_VALUES")"
    SVELTOS_CONFIG="$(sed '/^[[:space:]]*$/d' <<< "$SVELTOS_CONFIG")"
fi

read -ra providers <<< "$KCM_PROVIDERS"
MANAGEMENT_PROVIDERS=""
for provider in "${providers[@]}"; do
    MANAGEMENT_PROVIDERS+="  - name: $provider"$'\n'
    if [[ "$provider" == "projectsveltos" && -n "$SVELTOS_CONFIG" ]]; then
        MANAGEMENT_PROVIDERS+="    config:"$'\n'
        # shellcheck disable=SC2001 # per-line prefix, not a substring replace
        MANAGEMENT_PROVIDERS+="$(sed 's/^/      /' <<< "$SVELTOS_CONFIG")"$'\n'
    fi
done
# envsubst keeps the trailing newline; drop it so the YAML stays tidy.
MANAGEMENT_PROVIDERS="${MANAGEMENT_PROVIDERS%$'\n'}"
export MANAGEMENT_PROVIDERS RELEASE_NAME

MANIFEST="$ENVDIR/management.rendered.yaml"
envsubst < "$CONFIG_DIR/management.yaml" > "$MANIFEST"

# Management reinstalls the KCM component from the chart in the registry, so
# core.kcm.config must repeat the values we installed with -- otherwise it
# reverts to the published image and pulls fail. This is what the controller
# does for itself when createManagement is on.
VALUES_FILE="$ENVDIR/kcm-values.rendered.yaml"
[[ -f "$VALUES_FILE" ]] || die "$VALUES_FILE not found. Run ./scripts/deploy_kcm.sh first."
VALUES_FILE="$VALUES_FILE" yq -i '.spec.core.kcm.config = load(strenv(VALUES_FILE))' "$MANIFEST"

step "Applying Management (release $RELEASE_NAME, ${#providers[@]} providers)"
cat "$MANIFEST"
kube apply -f "$MANIFEST"

ok "Management applied"
