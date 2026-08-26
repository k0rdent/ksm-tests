#!/bin/bash
set -euo pipefail

# Clone/reuse the KCM repo, build the images, regenerate template manifests.
#
# Only the pure build targets are reused; dev-*/test-apply are kind-specific.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd git make docker go

ensure_workdir

if [[ -n "$KCM_SRC_DIR" ]]; then
    step "Using existing KCM checkout: $KCM_SRC_DIR"
    [[ -d "$KCM_SRC_DIR/.git" ]] || die "$KCM_SRC_DIR is not a git checkout"
else
    if [[ -d "$KCM_DIR/.git" ]]; then
        step "Updating KCM checkout at $KCM_DIR ($KCM_REF)"
        git -C "$KCM_DIR" fetch --tags --force origin
    else
        step "Cloning $KCM_REPO into $KCM_DIR"
        rm -rf "$KCM_DIR"
        git clone "$KCM_REPO" "$KCM_DIR"
    fi
    # Works for branches, tags and SHAs alike.
    git -C "$KCM_DIR" checkout --detach "origin/$KCM_REF" 2>/dev/null \
        || git -C "$KCM_DIR" checkout --detach "$KCM_REF"
fi

KCM_COMMIT="$(git -C "$KCM_DIR" rev-parse --short HEAD)"
KCM_VERSION="$(git -C "$KCM_DIR" describe --tags --always)"
KCM_VERSION="${KCM_VERSION#v}"
log "KCM commit $KCM_COMMIT (describe: $KCM_VERSION)"

step "Generating template manifests"
# Rewrites templates/provider/kcm-templates/files/templates/*.yaml so the
# ProviderTemplate/ClusterTemplate names match the chart versions in this tree.
make -C "$KCM_DIR" templates-generate

step "Building container images"
log "  controller: $IMG"
log "  telemetry:  $IMG_TELEMETRY"
make -C "$KCM_DIR" docker-build IMG="$IMG" IMG_TELEMETRY="$IMG_TELEMETRY"

# The chart version is what ends up in the Release object and in every template
# name -- record it so later steps and the logs agree on one number.
CHART_VERSION="$(chart_version "$KCM_DIR/templates/provider/kcm")"
{
    echo "KCM_COMMIT=$KCM_COMMIT"
    echo "KCM_DESCRIBE=$KCM_VERSION"
    echo "KCM_CHART_VERSION=$CHART_VERSION"
} > "$WORKDIR/kcm-build.env"

ok "Built KCM $CHART_VERSION from commit $KCM_COMMIT"
