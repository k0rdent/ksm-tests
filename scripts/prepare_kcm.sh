#!/bin/bash
set -euo pipefail

# Get the KCM artifacts ready for installation.
#
#   KCM_MODE=release  pulls the kcm-templates chart for the Release and the
#                     template manifests. No git at all: nothing has to line up
#                     with a tag, so release candidates and staging builds work
#                     the same as a final release.
#   KCM_MODE=source   clones SRC_URL, regenerates the template manifests and
#                     builds the controller and telemetry images.
#
# Only the pure build targets of the KCM Makefile are reused; dev-*/test-apply
# are kind-specific.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ensure_workdir

if [[ "$KCM_MODE" == "release" ]]; then
    require_cmd helm

    step "Fetching the manifests for $KCM_VERSION from $OCI_URL"
    # The same files a checkout used to carry, published alongside the chart
    # under test, so they always match it.
    rm -rf "$(kcm_chart_root)"
    helm pull "$OCI_URL/kcm-templates" --version "$KCM_VERSION" \
        --untar --untardir "$ENVDIR" >/dev/null \
        || die "No kcm-templates chart '$KCM_VERSION' in $OCI_URL"
    [[ -f "$(kcm_release_file)" ]] \
        || die "kcm-templates $KCM_VERSION has no $(kcm_release_file)"
    log "Release and templates from $OCI_URL/kcm-templates:$KCM_VERSION"

    CHART_VERSION="$KCM_VERSION"
    KCM_COMMIT=""
    KCM_DESCRIBE="$KCM_VERSION"
    KCM_COMMIT_DATE=""
else
    require_cmd git make docker go

    if [[ -n "$KCM_SRC_DIR" ]]; then
        step "Using existing KCM checkout: $KCM_SRC_DIR"
        [[ -d "$KCM_SRC_DIR/.git" ]] || die "$KCM_SRC_DIR is not a git checkout"
    else
        if [[ -d "$KCM_DIR/.git" ]]; then
            step "Updating KCM checkout at $KCM_DIR ($KCM_REF)"
            git -C "$KCM_DIR" fetch --tags --force origin
        else
            step "Cloning $SRC_URL into $KCM_DIR ($KCM_REF)"
            rm -rf "$KCM_DIR"
            git clone "$SRC_URL" "$KCM_DIR"
        fi
        # Works for branches, tags and SHAs alike.
        git -C "$KCM_DIR" checkout --detach "origin/$KCM_REF" 2>/dev/null \
            || git -C "$KCM_DIR" checkout --detach "$KCM_REF"
    fi

    KCM_COMMIT="$(git -C "$KCM_DIR" rev-parse --short HEAD)"
    KCM_DESCRIBE="$(git -C "$KCM_DIR" describe --tags --always)"
    KCM_DESCRIBE="${KCM_DESCRIBE#v}"
    # The date tells apart two builds of the same branch at a glance, which the
    # short sha alone does not.
    KCM_COMMIT_DATE="$(git -C "$KCM_DIR" show -s --format=%cd \
        --date=format:'%a %-d.%-m.%Y' HEAD)"
    log "KCM commit $KCM_COMMIT - $KCM_COMMIT_DATE (describe: $KCM_DESCRIBE)"

    step "Generating template manifests"
    # Rewrites templates/provider/kcm-templates/files/templates/*.yaml so the
    # template names match the chart versions in this tree.
    make -C "$KCM_DIR" templates-generate

    step "Building container images"
    log "  controller: $IMG"
    log "  telemetry:  $IMG_TELEMETRY"
    make -C "$KCM_DIR" docker-build IMG="$IMG" IMG_TELEMETRY="$IMG_TELEMETRY"

    # The chart version ends up in the Release object and every template name.
    CHART_VERSION="$(chart_version "$KCM_DIR/templates/provider/kcm")"
fi

# Quoted: the date contains spaces, and an unquoted value makes the file
# unsourceable.
{
    echo "KCM_COMMIT='$KCM_COMMIT'"
    echo "KCM_DESCRIBE='$KCM_DESCRIBE'"
    echo "KCM_COMMIT_DATE='$KCM_COMMIT_DATE'"
    echo "KCM_CHART_VERSION='$CHART_VERSION'"
    # What selected this build, so get_k0rdent_clusters.sh can report it.
    echo "KCM_MODE='$KCM_MODE'"
    echo "KCM_VARIANT='$KCM'"
    echo "KCM_REF='$KCM_REF'"
} > "$ENVDIR/kcm-build.env"

ok "KCM $CHART_VERSION ready ($KCM_MODE mode)"
