#!/bin/bash
# The service sets and the manifests rendered from them.
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

# ── SERVICE_SET picks the file ───────────────────────────────────────────────
# Unset SERVICES_FILE: this test process has already sourced common.sh, which
# exports it, and the child would inherit it instead of deriving it.
set_file() {
    SERVICE_SET="$1" bash -c "unset SERVICES_FILE; source '$SCRIPTS_DIR/lib/common.sh'; echo \$SERVICES_FILE"
}
assert_contains "traefik is the default set" "$(set_file '')" "services-traefik.yaml"
assert_contains "SERVICE_SET picks the kserve set" "$(set_file kserve)" "services-kserve.yaml"

for f in services-traefik services-kserve; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -f "$CONFIG_DIR/$f.yaml" ]]; then
        echo "  ✓ $f.yaml exists"
    else
        echo "  ✗ $f.yaml is missing"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done

# Every chart must come from catalog's registry, which is what the values
# nesting below assumes.
all_repos="$(yq -r '.services[].repo' "$CONFIG_DIR"/services-*.yaml | grep -v '^---$' | sort -u)"
assert_eq "all charts come from the catalog registry" \
    "oci://ghcr.io/k0rdent/catalog/charts" "$all_repos"

# ── The traefik set ──────────────────────────────────────────────────────────
SERVICES_FILE="$CONFIG_DIR/services-traefik.yaml"
assert_eq "traefik set has one service" 1 "$(service_count)"
assert_eq "traefik has no dependsOn" "" "$(service_field traefik dependsOn)"
assert_eq "traefik waits for its pods" "traefik-" "$(service_field traefik waitForPods)"

# ── The kserve set ───────────────────────────────────────────────────────────
SERVICES_FILE="$CONFIG_DIR/services-kserve.yaml"
assert_eq "kserve set has three services" 3 "$(service_count)"
assert_eq "declaration order puts dependencies first" \
    "cert-manager kserve-crd kserve-resources " \
    "$(services_rows | cut -d'|' -f1 | tr '\n' ' ')"
assert_eq "kserve-crd waits for cert-manager" "cert-manager" \
    "$(service_field kserve-crd dependsOn)"
assert_eq "kserve-resources waits for the CRDs" "kserve-crd" \
    "$(service_field kserve-resources dependsOn)"
assert_eq "namespaces are deduplicated" "cert-manager kserve" \
    "$(service_namespaces | tr '\n' ' ' | sed 's/ $//')"

# An empty optional field must not shift the later ones. A whitespace IFS
# collapses runs of separators, which silently moved waitForPods into dependsOn.
assert_eq "every row has 7 fields" 7 \
    "$(services_rows | head -1 | awk -F'|' '{print NF}')"
while IFS="$SERVICE_SEP" read -r n _c _v _r _ns dep wait; do
    [[ "$n" == cert-manager ]] || continue
    assert_eq "cert-manager has no dependsOn" "" "$dep"
    assert_eq "cert-manager keeps its waitForPods" "cert-manager-" "$wait"
done < <(services_rows)

assert_eq "OCI repos are typed for flux" "oci" \
    "$(repo_type oci://ghcr.io/k0rdent/catalog/charts)"
assert_eq "HTTP repos use the default type" "default" \
    "$(repo_type https://traefik.github.io/charts)"

# Catalog's charts are wrappers that declare the upstream chart as a dependency
# of the same name, so values MUST be nested under it. Flatten them and helm
# silently ignores the lot.
assert_contains "cert-manager values are nested under the chart name" \
    "$(service_values cert-manager)" "cert-manager:"
assert_contains "kserve values are nested under the chart name" \
    "$(service_values kserve-resources)" "kserve-resources:"

# ── Rendering the kserve set ─────────────────────────────────────────────────
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
export SERVICES_FILE

# The mocked kubectl never reports a template as valid, so cap the wait: this
# test is about what gets rendered, not about the cluster converging.
TEMPLATES_TIMEOUT=1 bash "$SCRIPTS_DIR/install_servicetemplate.sh" >/dev/null 2>&1 || true
tmpls="$(cat "$WORKDIR/service-templates.rendered.yaml" 2>/dev/null)"
assert_contains "renders the cert-manager ServiceTemplate" "$tmpls" "name: cert-manager-1-20-2"
assert_contains "renders the kserve ServiceTemplate" "$tmpls" "name: kserve-resources-0-18-0"
assert_contains "labels the repo for flux" "$tmpls" "k0rdent.mirantis.com/managed"
assert_contains "marks the catalog repo as OCI" "$tmpls" "type: oci"
# Anchored: sourceRef.kind says HelmRepository too.
assert_eq "one HelmRepository per service" 3 "$(grep -c '^kind: HelmRepository' <<< "$tmpls")"
assert_eq "one ServiceTemplate per service" 3 "$(grep -c '^kind: ServiceTemplate' <<< "$tmpls")"

SKIP_CHILD_API_CHECK=true MCS_TIMEOUT=1 \
    bash "$SCRIPTS_DIR/deploy_mcs.sh" >/dev/null 2>&1 || true
mcs="$(cat "$WORKDIR/service-mcs.rendered.yaml" 2>/dev/null)"
assert_contains "MCS lists cert-manager" "$mcs" "- template: cert-manager-1-20-2"
assert_contains "MCS targets the kserve namespace" "$mcs" "namespace: kserve"
assert_eq "MCS lists every service" 3 "$(grep -c '^      - template:' <<< "$mcs")"

# The values block must stay indented under the service, or the MCS is invalid.
assert_contains "values are nested under the service" "$mcs" "        values: |"
assert_contains "values keep their own indentation" "$mcs" "          cert-manager:"

# Confirm the rendered MCS is valid YAML with the shape KCM expects.
echo "$mcs" > "$WORKDIR/mcs.yaml"
assert_eq "rendered MCS parses as YAML" "MultiClusterService" \
    "$(yq -r '.kind' "$WORKDIR/mcs.yaml" 2>/dev/null)"
assert_eq "kserve-resources depends on kserve-crd" "kserve-crd" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="kserve-resources") | .dependsOn[0].name' "$WORKDIR/mcs.yaml" 2>/dev/null)"
assert_eq "the dependency carries its namespace" "cert-manager" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="kserve-crd") | .dependsOn[0].namespace' "$WORKDIR/mcs.yaml" 2>/dev/null)"
# Independent services must have no dependsOn at all -- a stray one makes KCM
# wait forever for a service that is never deployed.
assert_eq "cert-manager has no dependsOn in the MCS" "null" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .dependsOn' "$WORKDIR/mcs.yaml" 2>/dev/null)"
# The values must survive as a nested block, since the chart is a wrapper.
assert_eq "cert-manager values reach the subchart" "true" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .values' "$WORKDIR/mcs.yaml" 2>/dev/null | yq -r '.["cert-manager"].crds.enabled')"

rm -rf "$WORKDIR" "$MOCK_BIN"
finish
