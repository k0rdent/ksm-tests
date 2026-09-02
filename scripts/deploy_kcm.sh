#!/bin/bash
set -euo pipefail

# Install the KCM Helm chart.
#
#   KCM_MODE=source   from the source tree, so what runs is exactly what
#                       prepare_kcm.sh built
#   KCM_MODE=release  the published chart from ghcr, as a user would install it
#
# Both modes end up with a single rendered values file, because
# apply_management.sh has to copy exactly these values into core.kcm.config.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd helm kubectl envsubst
require_yq

export KUBECONFIG="$KUBECONFIG_MGMT"
ensure_workdir

VALUES_FILE="$WORKDIR/kcm-values.rendered.yaml"
envsubst < "$CONFIG_DIR/kcm-values.yaml" > "$VALUES_FILE"

helm_args=(--timeout 20m)

if [[ "$KCM_MODE" == "source" ]]; then
    CHART_REF="$KCM_DIR/templates/provider/kcm"
    [[ -d "$CHART_REF" ]] || die "KCM chart not found at $CHART_REF. Run ./scripts/prepare_kcm.sh first."

    # Split image references the way the KCM Makefile does, so the values file
    # can set repository and tag independently.
    IMG_REPO="${IMG%:*}"
    IMG_TAG="${IMG##*:}"
    IMG_TELEMETRY_REPO="${IMG_TELEMETRY%:*}"
    IMG_TELEMETRY_TAG="${IMG_TELEMETRY##*:}"
    export IMG_REPO IMG_TAG IMG_TELEMETRY_REPO IMG_TELEMETRY_TAG

    overlay="$WORKDIR/kcm-values-source.rendered.yaml"
    envsubst < "$CONFIG_DIR/kcm-values-source.yaml" > "$overlay"
    # shellcheck disable=SC2016 # $item is a yq variable, not a shell one
    yq eval-all '. as $item ireduce ({}; . * $item)' "$VALUES_FILE" "$overlay" \
        > "$VALUES_FILE.merged"
    mv "$VALUES_FILE.merged" "$VALUES_FILE"

    step "Resolving chart dependencies"
    # flux2 and rbac-manager come from remote repos, kcm-regional from file://.
    MAX_RETRIES=5 SLEEP=5 "$SCRIPTS_DIR/retry.sh" helm dependency update "$CHART_REF"
else
    CHART_REF="$KCM_RELEASE_URL"
    helm_args+=(--version "$KCM_VERSION")
fi

step "Rendered values ($VALUES_FILE)"
cat "$VALUES_FILE"

[[ "${DEBUG:-}" == "true" ]] && helm_args+=(--debug)

step "Installing $CHART_REF as release '$KCM_HELM_RELEASE_NAME' in '$NAMESPACE'"
helm upgrade --install "$KCM_HELM_RELEASE_NAME" "$CHART_REF" \
    -n "$NAMESPACE" --create-namespace \
    -f "$VALUES_FILE" \
    "${helm_args[@]}"

NAMESPACE="$NAMESPACE" "$SCRIPTS_DIR/wait_for_deployment.sh"

ok "KCM chart installed ($KCM_MODE mode)"
