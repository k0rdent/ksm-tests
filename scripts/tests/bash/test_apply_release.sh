#!/bin/bash
# Tests the Release trimming in scripts/apply_release.sh against a fake KCM tree.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

BIN_DIR="$REPO_ROOT/.work/bin"
export BIN_DIR
PATH="$BIN_DIR:$PATH"
if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "  ! mikefarah/yq not installed, skipping"
    exit 0
fi

setup_mock_bin
write_mock kubectl <<'EOF'
#!/bin/bash
exit 0
EOF

WORKDIR="$(mktemp -d)"
KCM_SRC_DIR="$WORKDIR/kcm"
TPL="$KCM_SRC_DIR/templates/provider/kcm-templates/files/templates"
mkdir -p "$TPL"
export WORKDIR KCM_SRC_DIR

cat > "$KCM_SRC_DIR/templates/provider/kcm-templates/files/release.yaml" <<'EOF'
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Release
metadata:
  name: kcm-1-11-0
spec:
  version: 1.11.0
  kcm:
    template: kcm-1-11-0
  regional:
    template: kcm-regional-1-11-0
  capi:
    template: cluster-api-1-1-15
  providers:
    - name: cluster-api-provider-aws
      template: cluster-api-provider-aws-1-0-26
    - name: cluster-api-provider-docker
      template: cluster-api-provider-docker-1-0-24
    - name: cluster-api-provider-azure
      template: cluster-api-provider-azure-1-0-31
    - name: projectsveltos
      template: projectsveltos-1-12-1
EOF

emit_template() { # emit_template FILE KIND NAME
    cat > "$TPL/$1" <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: $2
metadata:
  name: $3
EOF
}
emit_template kcm.yaml ProviderTemplate kcm-1-11-0
emit_template kcm-regional.yaml ProviderTemplate kcm-regional-1-11-0
emit_template cluster-api.yaml ProviderTemplate cluster-api-1-1-15
emit_template cluster-api-provider-docker.yaml ProviderTemplate cluster-api-provider-docker-1-0-24
emit_template cluster-api-provider-aws.yaml ProviderTemplate cluster-api-provider-aws-1-0-26
emit_template projectsveltos.yaml ProviderTemplate projectsveltos-1-12-1
emit_template adopted-cluster-1-0-2.yaml ClusterTemplate adopted-cluster-1-0-2

out=$(KCM_PROVIDERS="cluster-api-provider-docker projectsveltos" \
      KCM_CLUSTER_TEMPLATES="adopted-cluster" \
      bash "$SCRIPTS_DIR/apply_release.sh" 2>&1)
assert_eq "succeeds with a valid provider subset" 0 "$?"

trimmed="$(cat "$WORKDIR/release.trimmed.yaml")"
assert_contains "keeps the docker provider" "$trimmed" "cluster-api-provider-docker"
assert_contains "keeps sveltos" "$trimmed" "projectsveltos"
assert_not_contains "drops aws" "$trimmed" "cluster-api-provider-aws"
assert_not_contains "drops azure" "$trimmed" "cluster-api-provider-azure"
assert_contains "keeps the core kcm template" "$trimmed" "kcm-1-11-0"
assert_contains "keeps the capi template" "$trimmed" "cluster-api-1-1-15"

# shellcheck source=/dev/null
source "$WORKDIR/release.env"
assert_eq "records the Release name" "kcm-1-11-0" "$RELEASE_NAME"
assert_contains "records the provider templates" "$PROVIDER_TEMPLATES" "cluster-api-provider-docker-1-0-24"
assert_contains "records the core templates" "$PROVIDER_TEMPLATES" "kcm-regional-1-11-0"
assert_not_contains "does not record aws" "$PROVIDER_TEMPLATES" "aws"
assert_eq "records the cluster template" "adopted-cluster-1-0-2" "$CLUSTER_TEMPLATES"

# A provider that is not in the Release is a typo, not a silent no-op.
out=$(KCM_PROVIDERS="cluster-api-provider-nope" \
      bash "$SCRIPTS_DIR/apply_release.sh" 2>&1)
assert_eq "rejects an unknown provider" 1 "$?"
assert_contains "names the unknown provider" "$out" "cluster-api-provider-nope"

# A cluster template with no manifest must fail too.
out=$(KCM_PROVIDERS="projectsveltos" KCM_CLUSTER_TEMPLATES="does-not-exist" \
      bash "$SCRIPTS_DIR/apply_release.sh" 2>&1)
assert_eq "rejects a missing cluster template" 1 "$?"
assert_contains "names the missing template" "$out" "does-not-exist"

rm -rf "$WORKDIR" "$MOCK_BIN"
finish
