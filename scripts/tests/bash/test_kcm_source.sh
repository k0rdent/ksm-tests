#!/bin/bash
# KCM_SOURCE switches between the source build and the published chart.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

value_of() { # value_of KCM_SOURCE VAR
    KCM_SOURCE="$1" bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \"\${$2}\""
}

# Release mode reads charts straight from ghcr over TLS.
assert_eq "release: templatesRepoURL is ghcr" \
    "oci://ghcr.io/k0rdent/kcm/charts" "$(value_of release TEMPLATES_REPO_URL)"
assert_eq "release: registry is not insecure" \
    "false" "$(value_of release INSECURE_REGISTRY)"
assert_eq "release: checkout pinned to the matching tag" \
    "v1.11.0" "$(value_of release KCM_REF)"

# Source mode reads them from the local registry over plain HTTP.
assert_contains "source: templatesRepoURL is the local registry" \
    "$(value_of source TEMPLATES_REPO_URL)" "kcm-test-registry"
assert_eq "source: registry is insecure" \
    "true" "$(value_of source INSECURE_REGISTRY)"
assert_eq "source: checkout follows main" \
    "main" "$(value_of source KCM_REF)"

# An explicit KCM_REF always wins.
got="$(KCM_SOURCE=release KCM_REF=v1.10.0 bash -c \
    "source '$SCRIPTS_DIR/lib/common.sh'; echo \$KCM_REF")"
assert_eq "explicit KCM_REF overrides the default" "v1.10.0" "$got"

# A typo must not silently fall through to one of the modes.
out=$(KCM_SOURCE=relase bash -c "source '$SCRIPTS_DIR/lib/common.sh'; check_kcm_source" 2>&1)
assert_eq "invalid KCM_SOURCE is rejected" 1 "$?"
assert_contains "names the bad value" "$out" "relase"

for mode in source release; do
    KCM_SOURCE="$mode" bash -c "source '$SCRIPTS_DIR/lib/common.sh'; check_kcm_source" >/dev/null 2>&1
    assert_eq "'$mode' is accepted" 0 "$?"
done

# Release mode must run on a host with no Go toolchain: CI skips setup-go for
# that leg, so an unconditional check here fails the whole job. Real tools are
# used deliberately -- mocking curl or yq would only test the mocks.
nogo="$(mktemp -d)"
for d in /usr/bin /bin /usr/local/bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do [[ -x "$f" ]] && ln -sf "$f" "$nogo/$(basename "$f")" 2>/dev/null; done
done
rm -f "$nogo/go" "$nogo/make" "$nogo/gmake"

if [[ -x "$REPO_ROOT/.work/bin/yq" ]]; then
    ln -sf "$REPO_ROOT/.work/bin/yq" "$nogo/yq"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    out=$(PATH="$nogo" KCM_SOURCE=release BIN_DIR="$REPO_ROOT/.work/bin" \
          bash "$SCRIPTS_DIR/deps.sh" 2>&1)
    assert_eq "release mode succeeds without go/make" 0 "$?"
    assert_not_contains "does not ask for go" "$out" "'go' is required"

    out=$(PATH="$nogo" KCM_SOURCE=source BIN_DIR="$REPO_ROOT/.work/bin" \
          bash "$SCRIPTS_DIR/deps.sh" 2>&1)
    assert_eq "source mode fails without go/make" 1 "$?"
    assert_contains "says which mode needs it" "$out" "KCM_SOURCE=source"
else
    echo "  ! docker unavailable, skipping the deps.sh prerequisite checks"
fi

rm -rf "$nogo"

# ServiceTemplate naming has to match what the MCS references.
tn() { bash -c "source '$SCRIPTS_DIR/lib/common.sh'; source '$SCRIPTS_DIR/lib/services.sh'; template_name_for '$1' '$2'"; }
assert_eq "service template name" "traefik-41-2-0" "$(tn traefik 41.2.0)"
assert_eq "v-prefixed versions lose the v" "kserve-crd-0-18-0" "$(tn kserve-crd v0.18.0)"

finish
