#!/bin/bash
# The service set and the manifests rendered from it.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

BIN_DIR="$REPO_ROOT/.work/bin"
export BIN_DIR
PATH="$BIN_DIR:$PATH"
if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "  ! mikefarah/yq not installed, skipping"
    exit 0
fi

# shellcheck source=scripts/lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=scripts/lib/services.sh
source "$SCRIPTS_DIR/lib/services.sh"

# ── The shipped set ──────────────────────────────────────────────────────────
assert_eq "four services are declared" 4 "$(service_count)"

names="$(services_tsv | cut -f1 | tr '\n' ' ')"
assert_eq "declaration order puts dependencies first" \
    "traefik cert-manager kserve-crd kserve-resources " "$names"

assert_eq "kserve-crd waits for cert-manager" "cert-manager" \
    "$(service_field kserve-crd dependsOn)"
assert_eq "kserve-resources waits for the CRDs" "kserve-crd" \
    "$(service_field kserve-resources dependsOn)"

assert_eq "namespaces are deduplicated" "traefik cert-manager kserve" \
    "$(service_namespaces | tr '\n' ' ' | sed 's/ $//')"

assert_eq "OCI repos are typed for flux" "oci" \
    "$(repo_type oci://ghcr.io/kserve/charts)"
assert_eq "HTTP repos use the default type" "default" \
    "$(repo_type https://traefik.github.io/charts)"

# Catalog nests values under the chart name because it installs its own wrapper
# charts; against upstream charts that extra level would be ignored silently.
assert_contains "cert-manager values enable CRDs at top level" \
    "$(service_values cert-manager)" "crds:"
assert_not_contains "cert-manager values are not wrapped" \
    "$(service_values cert-manager)" "cert-manager:"
assert_contains "kserve values start at the kserve key" \
    "$(service_values kserve-resources)" "kserve:"
assert_not_contains "kserve values are not wrapped" \
    "$(service_values kserve-resources)" "kserve-resources:"

# ── Rendering ────────────────────────────────────────────────────────────────
setup_mock_bin
write_mock kubectl <<'EOF'
#!/bin/bash
exit 0
EOF

WORKDIR="$(mktemp -d)"
export WORKDIR
# require_cluster wants a regular file, and the mocked kubectl answers for it.
KUBECONFIG_MGMT="$WORKDIR/kubeconfig"
export KUBECONFIG_MGMT
echo "fake" > "$KUBECONFIG_MGMT"

# The mocked kubectl never reports a template as valid, so cap the wait: this
# test is about what gets rendered, not about the cluster converging.
TEMPLATES_TIMEOUT=1 bash "$SCRIPTS_DIR/install_servicetemplate.sh" >/dev/null 2>&1 || true
tmpls="$(cat "$WORKDIR/service-templates.rendered.yaml" 2>/dev/null)"
assert_contains "renders the traefik ServiceTemplate" "$tmpls" "name: traefik-41-2-0"
assert_contains "renders the kserve ServiceTemplate" "$tmpls" "name: kserve-resources-0-18-0"
assert_contains "labels the repo for flux" "$tmpls" "k0rdent.mirantis.com/managed"
assert_contains "marks the kserve repo as OCI" "$tmpls" "type: oci"
# Anchored: sourceRef.kind says HelmRepository too.
assert_eq "one HelmRepository per service" 4 "$(grep -c '^kind: HelmRepository' <<< "$tmpls")"
assert_eq "one ServiceTemplate per service" 4 "$(grep -c '^kind: ServiceTemplate' <<< "$tmpls")"

SKIP_CHILD_API_CHECK=true MCS_TIMEOUT=1 \
    bash "$SCRIPTS_DIR/deploy_mcs.sh" >/dev/null 2>&1 || true
mcs="$(cat "$WORKDIR/service-mcs.rendered.yaml" 2>/dev/null)"
assert_contains "MCS lists traefik" "$mcs" "- template: traefik-41-2-0"
assert_contains "MCS carries the dependency" "$mcs" "- name: cert-manager"
assert_contains "MCS targets the kserve namespace" "$mcs" "namespace: kserve"
assert_eq "MCS lists every service" 4 "$(grep -c '^      - template:' <<< "$mcs")"

# The values block must stay indented under the service, or the MCS is invalid.
assert_contains "values are nested under the service" "$mcs" "        values: |"
assert_contains "values keep their own indentation" "$mcs" "          crds:"

# Confirm the rendered MCS is valid YAML with the shape KCM expects.
echo "$mcs" > "$WORKDIR/mcs.yaml"
assert_eq "rendered MCS parses as YAML" "MultiClusterService" \
    "$(yq -r '.kind' "$WORKDIR/mcs.yaml" 2>/dev/null)"
assert_eq "kserve-resources depends on kserve-crd" "kserve-crd" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="kserve-resources") | .dependsOn[0].name' "$WORKDIR/mcs.yaml" 2>/dev/null)"

rm -rf "$WORKDIR" "$MOCK_BIN"
finish
