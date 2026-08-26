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
export WORKDIR
echo 'RELEASE_NAME=kcm-1-11-0' > "$WORKDIR/release.env"

KCM_PROVIDERS="cluster-api-provider-docker projectsveltos" \
    bash "$SCRIPTS_DIR/apply_management.sh" >/dev/null 2>&1
assert_eq "renders and applies successfully" 0 "$?"

rendered="$(cat "$WORKDIR/management.rendered.yaml")"
assert_contains "references the Release from release.env" "$rendered" "release: kcm-1-11-0"
assert_contains "lists the docker provider" "$rendered" "- name: cluster-api-provider-docker"
assert_contains "lists sveltos" "$rendered" "- name: projectsveltos"
assert_not_contains "does not enable aws" "$rendered" "cluster-api-provider-aws"
assert_eq "exactly 2 providers" 2 "$(grep -c '^  - name:' <<< "$rendered")"

# Without release.env the script must refuse rather than render junk.
rm -f "$WORKDIR/release.env"
out=$(bash "$SCRIPTS_DIR/apply_management.sh" 2>&1)
assert_eq "fails without release.env" 1 "$?"
assert_contains "points at apply_release.sh" "$out" "apply_release.sh"

rm -rf "$WORKDIR" "$MOCK_BIN"
finish
