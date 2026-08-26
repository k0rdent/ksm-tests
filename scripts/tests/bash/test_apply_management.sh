#!/bin/bash
# Tests the Management manifest apply_management.sh renders.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_mock_bin
write_mock kubectl <<'EOF'
#!/bin/bash
exit 0
EOF

WORKDIR="$(mktemp -d)"
# BIN_DIR normally lives under WORKDIR; keep pointing at the real tools.
BIN_DIR="$REPO_ROOT/.work/bin"
export WORKDIR BIN_DIR
echo 'RELEASE_NAME=kcm-1-11-0' > "$WORKDIR/release.env"
cat > "$WORKDIR/kcm-values.rendered.yaml" <<'EOF'
image:
  repository: localhost/kcm/controller
  tag: latest
controller:
  createManagement: false
EOF

KCM_PROVIDERS="cluster-api-provider-docker projectsveltos" \
    bash "$SCRIPTS_DIR/apply_management.sh" >/dev/null 2>&1
assert_eq "renders and applies successfully" 0 "$?"

rendered="$(cat "$WORKDIR/management.rendered.yaml")"
assert_contains "references the Release from release.env" "$rendered" "release: kcm-1-11-0"
assert_contains "lists the docker provider" "$rendered" "- name: cluster-api-provider-docker"
assert_contains "lists sveltos" "$rendered" "- name: projectsveltos"
assert_not_contains "does not enable aws" "$rendered" "cluster-api-provider-aws"
assert_eq "exactly 2 providers" 2 "$(grep -cE '^ +- name:' <<< "$rendered")"
# Without this the HelmRelease would reinstall KCM from the published image.
assert_contains "carries the local image into core.kcm.config" "$rendered" "localhost/kcm/controller"

# Missing inputs must fail loudly rather than render junk.
rm -f "$WORKDIR/kcm-values.rendered.yaml"
out=$(bash "$SCRIPTS_DIR/apply_management.sh" 2>&1)
assert_eq "fails without the rendered values" 1 "$?"
assert_contains "points at deploy_kcm.sh" "$out" "deploy_kcm.sh"

rm -f "$WORKDIR/release.env"
out=$(bash "$SCRIPTS_DIR/apply_management.sh" 2>&1)
assert_eq "fails without release.env" 1 "$?"
assert_contains "points at apply_release.sh" "$out" "apply_release.sh"

rm -rf "$WORKDIR" "$MOCK_BIN"
finish
