#!/bin/bash
set -euo pipefail

# Apply the Management object listing only $KCM_PROVIDERS.
#
# The chart runs with createManagement=false, so no default Management (which
# would enable every provider in the Release) is ever created.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl envsubst

RELEASE_ENV="$WORKDIR/release.env"
[[ -f "$RELEASE_ENV" ]] || die "$RELEASE_ENV not found. Run ./scripts/apply_release.sh first."
# shellcheck source=/dev/null
source "$RELEASE_ENV"
require_env RELEASE_NAME

export KUBECONFIG="$KUBECONFIG_MGMT"

read -ra providers <<< "$KCM_PROVIDERS"
MANAGEMENT_PROVIDERS=""
for provider in "${providers[@]}"; do
    MANAGEMENT_PROVIDERS+="  - name: $provider"$'\n'
done
# envsubst keeps the trailing newline; drop it so the YAML stays tidy.
MANAGEMENT_PROVIDERS="${MANAGEMENT_PROVIDERS%$'\n'}"
export MANAGEMENT_PROVIDERS RELEASE_NAME

MANIFEST="$WORKDIR/management.rendered.yaml"
envsubst < "$CONFIG_DIR/management.yaml" > "$MANIFEST"

step "Applying Management (release $RELEASE_NAME, ${#providers[@]} providers)"
cat "$MANIFEST"
kube apply -f "$MANIFEST"

ok "Management applied"
