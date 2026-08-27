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

# ── SCENARIO picks the file ──────────────────────────────────────────────────
# Unset SERVICES_FILE: this test process has already sourced common.sh, which
# exports it, and the child would inherit it instead of deriving it.
set_file() {
    SCENARIO="$1" bash -c "unset SERVICES_FILE; source '$SCRIPTS_DIR/lib/common.sh'; echo \$SERVICES_FILE"
}
assert_contains "01_basic is the default" "$(set_file '')" "01_basic.yaml"
assert_contains "SCENARIO picks the file" "$(set_file 02dep01_valid)" "02dep01_valid.yaml"
assert_eq "scenarios are discovered from the directory" \
    "01_basic 02dep01_valid 02dep02_invalid 03upg01_valid 03upg02_invalid_atomic" \
    "$(list_scenarios | tr '\n' ' ' | sed 's/ $//')"

# A typo must say what is available rather than just refuse.
out=$(SCENARIO=nope bash -c "unset SERVICES_FILE; source '$SCRIPTS_DIR/lib/common.sh'; check_scenario" 2>&1)
assert_eq "an unknown scenario is rejected" 1 "$?"
assert_contains "lists the available scenarios" "$out" "02dep01_valid"

# Underscores are legal in a filename but not in a Kubernetes object name, and
# the scenario reaches CLD_NAME and MCS_NAME.
slug="$(SCENARIO=02dep01_valid bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$SCENARIO_SLUG")"
assert_eq "the slug has no underscores" "02dep01-valid" "$slug"
mcs="$(SCENARIO=02dep01_valid bash -c "unset MCS_NAME; source '$SCRIPTS_DIR/lib/common.sh'; echo \$MCS_NAME")"
assert_not_contains "MCS_NAME has no underscores" "$mcs" "_"

# Metadata and filename must agree, or `make scenarios` and CI would disagree.
while read -r id; do
    [[ -n "$id" ]] || continue
    assert_eq "$id declares its own name" "$id" \
        "$(yq -r '.name' "$SCENARIOS_DIR/$id.yaml")"
    # The group is the outer layer of the hierarchy; without it a scenario
    # silently lands under "Ungrouped".
    assert_not_eq "$id declares a group" "" \
        "$(yq -r '.group // ""' "$SCENARIOS_DIR/$id.yaml")"
done < <(list_scenarios)

assert_eq "the dependency cases share one group" "Service dependencies" \
    "$(yq -r '.group' "$SCENARIOS_DIR/02dep01_valid.yaml")"
assert_eq "both dependency cases are in it" "Service dependencies" \
    "$(yq -r '.group' "$SCENARIOS_DIR/02dep02_invalid.yaml")"

assert_eq "01 has no known failures" "0" \
    "$(yq -r '[.knownFailures[]] | length' "$SCENARIOS_DIR/01_basic.yaml")"
assert_eq "02 records the 1.11.0 defect" "rel-1-11-0" \
    "$(yq -r '.knownFailures[0].kcm' "$SCENARIOS_DIR/02dep01_valid.yaml")"

# Every chart must come from catalog's registry, which is what the values
# nesting below assumes.
all_repos="$(yq -r '.services[].repo' "$SCENARIOS_DIR"/*.yaml | grep -v '^---$' | sort -u)"
assert_eq "all charts come from the catalog registry" \
    "oci://ghcr.io/k0rdent/catalog/charts" "$all_repos"

# ── 01_basic ────────────────────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/01_basic.yaml"
assert_eq "01 has one service" 1 "$(service_count)"
assert_eq "traefik has no dependsOn" "" "$(service_field traefik dependsOn)"
assert_eq "traefik waits for its pods" "traefik-" "$(service_field traefik waitForPods)"

# ── 02dep01_valid ──────────────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/02dep01_valid.yaml"
assert_eq "02 has three services" 3 "$(service_count)"
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

# ── 02dep02_invalid: the expect block ────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/01_basic.yaml"
assert_eq "01_basic expects no failure" "1" "$(expects_failure && echo 0 || echo 1)"
SERVICES_FILE="$SCENARIOS_DIR/02dep01_valid.yaml"
assert_eq "the valid chain expects no failure" "1" "$(expects_failure && echo 0 || echo 1)"

SERVICES_FILE="$SCENARIOS_DIR/02dep02_invalid.yaml"
assert_eq "the invalid chain expects a failure" "0" "$(expects_failure && echo 0 || echo 1)"
assert_eq "it names the failing service" "cert-manager" "$(expect_field failed)"
assert_eq "graceSeconds is set" "120" "$(expect_field graceSeconds)"
assert_eq "one blocked service" "kserve-crd" "$(expect_list blocked | tr '\n' ' ' | sed 's/ $//')"
assert_eq "one already-deployed service" "traefik" "$(expect_list deployed | tr '\n' ' ' | sed 's/ $//')"

# A name that is not a service in the file would make the whole scenario
# vacuous: nothing would ever be checked and the run would go green.
known_services="$(services_rows | cut -d'|' -f1)"
check_names() { # check_names FIELD < names
    while read -r n; do
        [[ -n "$n" ]] || continue
        assert_contains "expect.$1 '$n' is a declared service" "$known_services" "$n"
    done
}
expect_field failed | check_names failed
expect_list blocked | check_names blocked
expect_list deployed | check_names deployed

# depends_transitively CHILD ANCESTOR -- follow dependsOn up the chain.
depends_transitively() {
    local cur="$1" guard=0
    while [[ -n "$cur" ]] && (( guard < 10 )); do
        cur="$(service_field "$cur" dependsOn)"
        [[ "$cur" == "$2" ]] && return 0
        guard=$(( guard + 1 ))
    done
    return 1
}

# The claims only mean something if the graph actually has this shape: blocked
# services must sit behind the failure, kept ones in front of it.
while read -r n; do
    [[ -n "$n" ]] || continue
    assert_eq "blocked '$n' really depends on the failing service" "0" \
        "$(depends_transitively "$n" "$(expect_field failed)" && echo 0 || echo 1)"
done < <(expect_list blocked)

while read -r n; do
    [[ -n "$n" ]] || continue
    assert_eq "kept '$n' does not depend on the failing service" "1" \
        "$(depends_transitively "$n" "$(expect_field failed)" && echo 0 || echo 1)"
done < <(expect_list deployed)

# ── Upgrades ─────────────────────────────────────────────────────────────────
SERVICES_FILE="$SCENARIOS_DIR/01_basic.yaml"
assert_eq "01_basic has no upgrade block" "1" "$(has_upgrade && echo 0 || echo 1)"

SERVICES_FILE="$SCENARIOS_DIR/03upg01_valid.yaml"
assert_eq "the valid upgrade has one" "0" "$(has_upgrade && echo 0 || echo 1)"
assert_eq "it upgrades cert-manager" "cert-manager" "$(upgrade_names | tr '\n' ' ' | sed 's/ $//')"
assert_eq "to a version that exists" "1.21.1" "$(upgrade_field cert-manager version)"
assert_eq "it is not atomic" "false" "$(scenario_atomic)"
# The override must apply only in upgraded mode, or the first deploy would
# already install the new version and there would be nothing to upgrade.
assert_eq "the initial deploy keeps the old version" "1.20.2" \
    "$(effective_version cert-manager initial)"
assert_eq "the upgrade moves to the new one" "1.21.1" \
    "$(effective_version cert-manager upgraded)"
assert_eq "services with no override are unaffected" "41.2.0" \
    "$(effective_version traefik upgraded)"

# An upgrade that changes nothing would pass every check while testing nothing.
before="$(mktemp)"; after="$(mktemp)"
render_mcs "$before" initial; render_mcs "$after" upgraded
assert_eq "the initial MCS pins the old template" "cert-manager-1-20-2" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .template' "$before")"
assert_eq "the upgraded MCS pins the new one" "cert-manager-1-21-1" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .template' "$after")"
assert_eq "untouched services keep their template" "traefik-41-2-0" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="traefik") | .template' "$after")"

SERVICES_FILE="$SCENARIOS_DIR/03upg02_invalid_atomic.yaml"
assert_eq "the atomic scenario sets atomic" "true" "$(scenario_atomic)"
assert_eq "it expects a failure" "cert-manager" "$(upgrade_expect_field failed)"
assert_eq "and a rollback target" "1.20.2" "$(upgrade_expect_field rolledBackTo)"
# The rollback target must be the version actually deployed first, otherwise
# the assertion could pass against a version that was never running.
assert_eq "the rollback target is the deployed version" \
    "$(service_field cert-manager version)" "$(upgrade_expect_field rolledBackTo)"
assert_contains "the values override applies" "$(effective_values cert-manager upgraded)" \
    "replicaCount: -1"
# The upgrade must be a real version change too, not a bare values edit --
# otherwise it exercises a different code path in the provider.
assert_eq "the atomic upgrade also bumps the version" "1.21.1" \
    "$(effective_version cert-manager upgraded)"
assert_eq "and starts from the rollback target" "1.20.2" \
    "$(effective_version cert-manager initial)"
# The override replaces rather than merges, so anything that must survive the
# upgrade has to be repeated in it. Only replicaCount should differ.
assert_contains "the override repeats what must survive" \
    "$(effective_values cert-manager upgraded)" "crds:"
assert_not_contains "the initial values are not invalid" \
    "$(effective_values cert-manager initial)" "replicaCount"

render_mcs "$after" upgraded
assert_eq "atomic reaches every service in the MCS" "true" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .helmOptions.atomic' "$after")"
assert_eq "the atomic upgrade pins the new chart version" "cert-manager-1-21-1" \
    "$(yq -r '.spec.serviceSpec.services[] | select(.name=="cert-manager") | .template' "$after")"
assert_contains "the invalid values are rendered" "$(cat "$after")" "replicaCount: -1"
rm -f "$before" "$after"

# Every name in upgrade.expect must be a real service, same trap as expect:.
known_services="$(services_rows | cut -d'|' -f1)"
for f in rolledOut untouched; do
    while read -r n; do
        [[ -n "$n" ]] || continue
        assert_contains "upgrade.expect.$f '$n' is a declared service" "$known_services" "$n"
    done < <(upgrade_expect_list "$f")
done

# ── Rendering 02dep01_valid ────────────────────────────────────────────
# Back to the valid chain: the block above pointed SERVICES_FILE elsewhere.
SERVICES_FILE="$SCENARIOS_DIR/02dep01_valid.yaml"
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
