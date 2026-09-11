#!/bin/bash
# KCM selects the build and names the environment; KCM_MODE switches between
# the published chart and a source build.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# This process has not sourced common.sh, so each child starts clean.
value_of() { # value_of KCM_MODE VAR
    KCM_MODE="$1" bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \"\${$2}\""
}

# ── Modes ────────────────────────────────────────────────────────────────────
# Release mode reads charts straight from ghcr over TLS.
assert_eq "release: templatesRepoURL is ghcr" \
    "oci://ghcr.io/k0rdent/kcm/charts" "$(value_of release TEMPLATES_REPO_URL)"
assert_eq "release: registry is not insecure" \
    "false" "$(value_of release INSECURE_REGISTRY)"
# Release mode needs no git at all: the manifests come from the registry, so
# nothing has to correspond to a tag. That is what lets an -rc or a staging
# build work, since their chart version is not one.
assert_eq "release: the registry is the source of everything" \
    "oci://ghcr.io/k0rdent/kcm/charts" "$(value_of release OCI_URL)"

# Source mode reads them from the local registry over plain HTTP.
assert_contains "source: templatesRepoURL is the local registry" \
    "$(value_of source TEMPLATES_REPO_URL)" "kcm-registry"
assert_eq "source: registry is insecure" \
    "true" "$(value_of source INSECURE_REGISTRY)"
assert_eq "source: checkout follows main" \
    "main" "$(value_of source KCM_REF)"

# An explicit KCM_REF always wins.
got="$(KCM_MODE=release KCM_REF=v1.10.0 bash -c \
    "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_REF")"
assert_eq "explicit KCM_REF overrides the default" "v1.10.0" "$got"

# A typo must not silently fall through to one of the modes. Sourcing the
# library is enough -- no script has to remember to call a checker.
out=$(KCM_MODE=relase bash -c "source '$SCRIPTS_DIR/lib/common.sh'" 2>&1)
assert_eq "invalid KCM_MODE is rejected" 1 "$?"
assert_contains "names the bad value" "$out" "relase"

for mode in source release; do
    KCM_MODE="$mode" bash -c "source '$SCRIPTS_DIR/lib/common.sh'" >/dev/null 2>&1
    assert_eq "'$mode' is accepted" 0 "$?"
done

# The default is the published chart: a plain run tests what users install.
assert_eq "mode defaults to release" "release" \
    "$(bash -c "unset KCM KCM_MODE; source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_MODE")"

# TEST_MODE is validated the same way, and for the same reason: a value left
# over from another project used to reach the cluster build.
out=$(TEST_MODE=adopted bash -c "source '$SCRIPTS_DIR/lib/common.sh'" 2>&1)
assert_eq "invalid TEST_MODE is rejected" 1 "$?"
assert_contains "names the bad value" "$out" "adopted"

# ── KCM is the version, the ref, and the name ────────────────────────────────
assert_eq "KCM is the chart version in release mode" "1.12.0-rc1" \
    "$(KCM=1.12.0-rc1 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_VERSION")"
assert_eq "and the git ref in source mode" "480aad76" \
    "$(KCM=480aad76 KCM_MODE=source bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_REF")"
# A branch name in release mode is a typo, not a chart nobody published.
out="$(KCM=my-branch bash -c "source '$SCRIPTS_DIR/lib/common.sh'" 2>&1)"
assert_eq "a non-version is refused in release mode" 1 "$?"
assert_contains "and says how to build a ref" "$out" "KCM_MODE=source"

# The environment scripts cannot guess which cluster is meant.
out="$(KCM='' bash -c "source '$SCRIPTS_DIR/lib/common.sh'; require_kcm" 2>&1)"
assert_eq "require_kcm fails without KCM" 1 "$?"
assert_contains "and says what KCM is for" "$out" "k0rdent-<KCM>"

# Everything two environments could collide on is keyed by KCM.
names_for() { # names_for KCM
    KCM="$1" bash -c "
        source '$SCRIPTS_DIR/lib/common.sh'
        echo \"\$MGMT_CLUSTER_NAME|\$REGISTRY_NAME|\$ENVDIR|\$KUBECONFIG_NAMED|\$IMG|\$IMG_TELEMETRY\""
}
IFS='|' read -ra fa <<< "$(names_for 1.11.0)"
IFS='|' read -ra fb <<< "$(names_for 1.12.0-rc1)"
labels=(MGMT_CLUSTER_NAME REGISTRY_NAME ENVDIR KUBECONFIG_NAMED IMG IMG_TELEMETRY)
for i in "${!labels[@]}"; do
    assert_not_eq "${labels[$i]} differs between environments" "${fa[$i]}" "${fb[$i]}"
done

assert_eq "the cluster is named after KCM" "k0rdent-1.11.0" \
    "$(KCM=1.11.0 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$MGMT_CLUSTER_NAME")"
assert_eq "and so is its kubeconfig" "$REPO_ROOT/kcfg_k0rdent_1.11.0" \
    "$(KCM=1.11.0 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KUBECONFIG_NAMED")"
# The scenario scripts read this one and never KCM, so a cluster you built
# yourself works as well as one deploy_k0rdent.sh built.
assert_eq "scenarios always read the plain name" "$REPO_ROOT/kcfg_k0rdent" \
    "$(KCM=1.11.0 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KUBECONFIG_MGMT")"
# Tools are deliberately shared -- re-downloading them per environment is waste.
assert_eq "BIN_DIR is shared" \
    "$(KCM=1.11.0 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$BIN_DIR")" \
    "$(KCM=1.12.0 bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$BIN_DIR")"

# A fork and an arbitrary commit are both reachable.
got="$(KCM_MODE=source SRC_URL=https://github.com/me/kcm.git KCM_REF=480aad76 \
    bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$SRC_URL \$KCM_REF")"
assert_eq "fork url and commit are honoured" "https://github.com/me/kcm.git 480aad76" "$got"

assert_eq "OCI_URL is what KCM pulls its templates from" "oci://reg.example/charts" \
    "$(KCM_MODE=release OCI_URL=oci://reg.example/charts bash -c \
        "unset TEMPLATES_REPO_URL; source '$SCRIPTS_DIR/lib/common.sh'; echo \$TEMPLATES_REPO_URL")"

# ── Prerequisites ────────────────────────────────────────────────────────────
# Release mode must run on a host with no Go toolchain: CI skips setup-go for
# that leg, so an unconditional check here fails the whole job. Real tools are
# used deliberately -- mocking curl or yq would only test the mocks.
nogo="$(mktemp -d)"
for d in /usr/bin /bin /usr/local/bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do [[ -x "$f" ]] && ln -sf "$f" "$nogo/$(basename "$f")" 2>/dev/null; done
done
rm -f "$nogo/go" "$nogo/make" "$nogo/gmake"

if [[ -x "$REPO_ROOT/.bin/yq" ]]; then
    ln -sf "$REPO_ROOT/.bin/yq" "$nogo/yq"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    out=$(PATH="$nogo" KCM_MODE=release BIN_DIR="$REPO_ROOT/.bin" \
          bash "$SCRIPTS_DIR/steps/deps.sh" 2>&1)
    assert_eq "release mode succeeds without go/make" 0 "$?"
    assert_not_contains "does not ask for go" "$out" "'go' is required"

    out=$(PATH="$nogo" KCM_MODE=source BIN_DIR="$REPO_ROOT/.bin" \
          bash "$SCRIPTS_DIR/steps/deps.sh" 2>&1)
    assert_eq "source mode fails without go/make" 1 "$?"
    assert_contains "says which mode needs it" "$out" "KCM_MODE=source"
else
    echo "  ! docker unavailable, skipping the deps.sh prerequisite checks"
fi

rm -rf "$nogo"

# ServiceTemplate naming has to match what the MCS references.
tn() { bash -c "source '$SCRIPTS_DIR/lib/common.sh'; source '$SCRIPTS_DIR/lib/services.sh'; template_name_for '$1' '$2'"; }
assert_eq "service template name" "traefik-41-2-0" "$(tn traefik 41.2.0)"
assert_eq "v-prefixed versions lose the v" "kserve-crd-0-18-0" "$(tn kserve-crd v0.18.0)"

finish
