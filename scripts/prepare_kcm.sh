#!/bin/bash
set -euo pipefail

# Get the KCM artifacts ready for installation.
#
# Both modes need the checkout: it supplies the Release and template manifests.
#   KCM_MODE=source   also builds the controller/telemetry images and
#                     regenerates the template manifests from the charts.
#   KCM_MODE=release  stops after the checkout; the chart comes from the registry.
#
# Only the pure build targets of the KCM Makefile are reused; dev-*/test-apply
# are kind-specific.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd git
[[ "$KCM_MODE" == "source" ]] && require_cmd make docker go

ensure_workdir

if [[ -n "$KCM_SRC_DIR" ]]; then
    step "Using existing KCM checkout: $KCM_SRC_DIR"
    [[ -d "$KCM_SRC_DIR/.git" ]] || die "$KCM_SRC_DIR is not a git checkout"
else
    if [[ -d "$KCM_DIR/.git" ]]; then
        step "Updating KCM checkout at $KCM_DIR ($KCM_REF)"
        git -C "$KCM_DIR" fetch --tags --force origin
    else
        step "Cloning $KCM_SRC_URL into $KCM_DIR ($KCM_REF)"
        rm -rf "$KCM_DIR"
        git clone "$KCM_SRC_URL" "$KCM_DIR"
    fi
    # Works for branches, tags and SHAs alike.
    git -C "$KCM_DIR" checkout --detach "origin/$KCM_REF" 2>/dev/null \
        || git -C "$KCM_DIR" checkout --detach "$KCM_REF"
fi

KCM_COMMIT="$(git -C "$KCM_DIR" rev-parse --short HEAD)"
KCM_DESCRIBE="$(git -C "$KCM_DIR" describe --tags --always)"
KCM_DESCRIBE="${KCM_DESCRIBE#v}"
log "KCM commit $KCM_COMMIT (describe: $KCM_DESCRIBE)"

if [[ "$KCM_MODE" == "source" ]]; then
    step "Generating template manifests"
    # Rewrites templates/provider/kcm-templates/files/templates/*.yaml so the
    # template names match the chart versions in this tree.
    make -C "$KCM_DIR" templates-generate

    step "Building container images"
    log "  controller: $IMG"
    log "  telemetry:  $IMG_TELEMETRY"
    make -C "$KCM_DIR" docker-build IMG="$IMG" IMG_TELEMETRY="$IMG_TELEMETRY"
else
    step "Release mode: using the published chart $KCM_RELEASE_URL:$KCM_VERSION"
    log "No build; the checkout only supplies the Release and template manifests."
fi

# The chart version ends up in the Release object and every template name --
# record it so later steps and the logs agree on one number.
CHART_VERSION="$(chart_version "$KCM_DIR/templates/provider/kcm")"

if [[ "$KCM_MODE" == "release" && "$CHART_VERSION" != "$KCM_VERSION" ]]; then
    die "Checkout $KCM_REF has chart version $CHART_VERSION but KCM_VERSION is $KCM_VERSION.
The manifests would not match the published chart. Set KCM_REF to the matching tag."
fi

{
    echo "KCM_COMMIT=$KCM_COMMIT"
    echo "KCM_DESCRIBE=$KCM_DESCRIBE"
    echo "KCM_CHART_VERSION=$CHART_VERSION"
} > "$WORKDIR/kcm-build.env"

ok "KCM $CHART_VERSION ready from commit $KCM_COMMIT ($KCM_MODE mode)"
