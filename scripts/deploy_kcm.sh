#!/bin/bash
set -euo pipefail

# Install the KCM Helm chart straight from the source tree, so what runs is
# exactly what build_kcm.sh produced.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd helm kubectl envsubst

CHART_DIR="$KCM_DIR/templates/provider/kcm"
[[ -d "$CHART_DIR" ]] || die "KCM chart not found at $CHART_DIR. Run ./scripts/build_kcm.sh first."

export KUBECONFIG="$KUBECONFIG_MGMT"

# Split image references the way the KCM Makefile does, so the values file can
# set repository and tag independently.
IMG_REPO="${IMG%:*}"
IMG_TAG="${IMG##*:}"
IMG_TELEMETRY_REPO="${IMG_TELEMETRY%:*}"
IMG_TELEMETRY_TAG="${IMG_TELEMETRY##*:}"
export IMG_REPO IMG_TAG IMG_TELEMETRY_REPO IMG_TELEMETRY_TAG

ensure_workdir
VALUES_FILE="$WORKDIR/kcm-values.rendered.yaml"
envsubst < "$CONFIG_DIR/kcm-values.yaml" > "$VALUES_FILE"

step "Rendered values ($VALUES_FILE)"
cat "$VALUES_FILE"

step "Resolving chart dependencies"
# flux2 and rbac-manager come from remote repos, kcm-regional from file://.
MAX_RETRIES=5 SLEEP=5 "$SCRIPTS_DIR/retry.sh" helm dependency update "$CHART_DIR"

helm_flags=(--timeout 20m)
[[ "${DEBUG:-}" == "true" ]] && helm_flags+=(--debug)

step "Installing KCM chart as release '$KCM_HELM_RELEASE_NAME' in '$NAMESPACE'"
helm upgrade --install "$KCM_HELM_RELEASE_NAME" "$CHART_DIR" \
    -n "$NAMESPACE" --create-namespace \
    -f "$VALUES_FILE" \
    "${helm_flags[@]}"

NAMESPACE="$NAMESPACE" "$SCRIPTS_DIR/wait_for_deployment.sh"

ok "KCM chart installed"
