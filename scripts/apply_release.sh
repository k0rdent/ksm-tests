#!/bin/bash
set -euo pipefail

# Apply a Release trimmed to $KCM_PROVIDERS plus the templates it references.
#
# The Release must be trimmed, not just the templates: the Release goes Ready
# only when every template it lists is valid, and Management waits on that.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

require_cmd kubectl
require_yq

RELEASE_FILE="$(kcm_release_file)"
TEMPLATES_DIR_KCM="$(kcm_templates_dir)"
[[ -f "$RELEASE_FILE" ]] || die "Release manifest not found at $RELEASE_FILE. Run ./scripts/prepare_kcm.sh first."

export KUBECONFIG="$KUBECONFIG_MGMT"
ensure_workdir

read -ra providers <<< "$KCM_PROVIDERS"
read -ra cluster_templates <<< "$KCM_CLUSTER_TEMPLATES"

step "Trimming the Release to ${#providers[@]} provider(s)"

# Fail fast on a typo instead of silently installing fewer providers.
for provider in "${providers[@]}"; do
    yq -e ".spec.providers[] | select(.name == \"$provider\")" "$RELEASE_FILE" >/dev/null 2>&1 \
        || die "Provider '$provider' is not part of $RELEASE_FILE"
done

# Build `.name == "a" or .name == "b"` for the yq select.
select_expr=""
for provider in "${providers[@]}"; do
    [[ -n "$select_expr" ]] && select_expr+=" or "
    select_expr+=".name == \"$provider\""
done

TRIMMED_RELEASE="$WORKDIR/release.trimmed.yaml"
yq ".spec.providers |= map(select($select_expr))" "$RELEASE_FILE" > "$TRIMMED_RELEASE"

RELEASE_NAME="$(yq -r '.metadata.name' "$TRIMMED_RELEASE")"
[[ -n "$RELEASE_NAME" && "$RELEASE_NAME" != "null" ]] || die "Could not read the Release name from $TRIMMED_RELEASE"

log "Release: $RELEASE_NAME (version $(yq -r '.spec.version' "$TRIMMED_RELEASE"))"
yq -r '.spec.providers[].name' "$TRIMMED_RELEASE" | sed 's/^/     - /'

step "Applying ProviderTemplates"
# Core templates the Release always references, plus one file per provider.
# hack/templates.sh names ProviderTemplate files after the chart, not the version.
provider_files=("$TEMPLATES_DIR_KCM/kcm.yaml" "$TEMPLATES_DIR_KCM/kcm-regional.yaml" "$TEMPLATES_DIR_KCM/cluster-api.yaml")
for provider in "${providers[@]}"; do
    provider_files+=("$TEMPLATES_DIR_KCM/$provider.yaml")
done
applied_provider_templates=()
for file in "${provider_files[@]}"; do
    [[ -f "$file" ]] || die "Missing template manifest: $file"
    log "$(basename "$file")"
    kube apply -f "$file"
    applied_provider_templates+=("$(yq -r '.metadata.name' "$file")")
done

step "Applying ClusterTemplates"
applied_cluster_templates=()
for name in "${cluster_templates[@]}"; do
    # ClusterTemplate files carry the chart version in their name, so glob.
    shopt -s nullglob
    matches=("$TEMPLATES_DIR_KCM/$name"-[0-9]*.yaml)
    shopt -u nullglob
    [[ ${#matches[@]} -gt 0 ]] || die "No ClusterTemplate manifest for '$name' in $TEMPLATES_DIR_KCM"
    for file in "${matches[@]}"; do
        log "$(basename "$file")"
        kube apply -n "$NAMESPACE" -f "$file"
        applied_cluster_templates+=("$(yq -r '.metadata.name' "$file")")
    done
done

step "Applying the Release"
kube apply -f "$TRIMMED_RELEASE"

# Downstream scripts read these instead of re-deriving names from chart versions.
{
    echo "RELEASE_NAME=$RELEASE_NAME"
    echo "PROVIDER_TEMPLATES=\"${applied_provider_templates[*]}\""
    echo "CLUSTER_TEMPLATES=\"${applied_cluster_templates[*]}\""
} > "$WORKDIR/release.env"

ok "Release '$RELEASE_NAME' and its templates applied"
