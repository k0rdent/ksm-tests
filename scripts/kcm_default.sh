#!/usr/bin/env bash
set -euo pipefail

# The KCM build this repository tests by default: the variant marked
# `prCheck: true` in scripts/config/kcm-variants.yaml.
#
# One place names it. Everything that needs a default -- a manual workflow run,
# a pull request, a local ./scripts/deploy_k0rdent.sh -- reads it from here
# rather than carrying its own copy, so bumping the variant bumps all of them.
#
# Prints shell assignments, usable three ways:
#   eval "$(./scripts/kcm_default.sh --export)"   # locally
#   ./scripts/kcm_default.sh >> "$GITHUB_ENV"     # in CI
#   KCM=$(./scripts/kcm_default.sh --version)     # just the version
#
# --export is what a shell needs and GITHUB_ENV must not have: a plain KCM=...
# is a shell variable, which the deploy scripts never see because they run as
# child processes. The CI form is a file in `name=value` lines and would take
# the word `export` as part of the name.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_yq

VARIANTS="$CONFIG_DIR/kcm-variants.yaml"
[[ -f "$VARIANTS" ]] || die "No $VARIANTS"

sel='.variants[] | select(.prCheck == true)'
kcm="$(yq -r "$sel | .kcm // \"\"" "$VARIANTS")"
mode="$(yq -r "$sel | .mode // \"\"" "$VARIANTS")"
oci="$(yq -r "$sel | .oci // \"\"" "$VARIANTS")"

[[ -n "$kcm" ]] \
    || die "No variant in $VARIANTS has 'prCheck: true', so there is no default build."

case "${1:-}" in
    --version) echo "$kcm"; exit 0 ;;
    --export)  prefix="export " ;;
    "")        prefix="" ;;
    *)         die "Unknown option '$1'. Use --version or --export." ;;
esac

echo "${prefix}KCM=$kcm"
echo "${prefix}KCM_MODE=$mode"
# Only when the variant carries one; otherwise common.sh's own default applies.
[[ -n "$oci" ]] && echo "${prefix}OCI_URL=$oci"
exit 0
