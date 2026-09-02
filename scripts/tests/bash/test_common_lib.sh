#!/bin/bash
# Tests for scripts/lib/common.sh
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

# ── fqdn_version ─────────────────────────────────────────────────────────────
assert_eq "1.11.0 -> 1-11-0" "1-11-0" "$(fqdn_version 1.11.0)"
assert_eq "strips the v prefix" "1-11-0" "$(fqdn_version v1.11.0)"
assert_eq "handles pre-release suffixes" "1-11-0-rc1" "$(fqdn_version 1.11.0-rc1)"
assert_eq "single component" "2" "$(fqdn_version 2)"

# ── paths ────────────────────────────────────────────────────────────────────
assert_eq "PROJECT_ROOT points at the repo" "$REPO_ROOT" "$PROJECT_ROOT"
assert_eq "CONFIG_DIR is derived from it" "$REPO_ROOT/scripts/config" "$CONFIG_DIR"

# ── defaults ─────────────────────────────────────────────────────────────────
assert_eq "TEST_MODE defaults to adopted" "adopted" "$TEST_MODE"
assert_eq "CLD_NAME is <mode>-<suffix>" "adopted-e2e" "$CLD_NAME"
assert_contains "sveltos is enabled" "$KCM_PROVIDERS" "projectsveltos"
# The adopted template needs no provider of its own, so anything else here
# would just be a chart KCM reconciles for nothing.
assert_eq "sveltos is the whole provider list" "projectsveltos" "$KCM_PROVIDERS"
assert_eq "and the adopted cluster template" "adopted-cluster" "$KCM_CLUSTER_TEMPLATES"
assert_not_contains "aws provider is off" "$KCM_PROVIDERS" "cluster-api-provider-aws"
assert_not_contains "azure provider is off" "$KCM_PROVIDERS" "cluster-api-provider-azure"
# Only source mode uses the local registry; release mode pulls from the URL.
assert_eq "registry URL matches the registry name" "oci://$REGISTRY_NAME:5000/charts" \
    "$(KCM_MODE=source bash -c \
        "unset TEMPLATES_REPO_URL; source '$SCRIPTS_DIR/lib/common.sh'; echo \$TEMPLATES_REPO_URL")"

# ── chart helpers ────────────────────────────────────────────────────────────
tmpchart="$(mktemp -d)/mychart"
mkdir -p "$tmpchart"
cat > "$tmpchart/Chart.yaml" <<'EOF'
apiVersion: v2
name: adopted-cluster
description: |
  version: 9.9.9 should not be picked up from an indented line
type: application
version: 1.0.2
appVersion: "v1.36.1+k0s.0"
EOF
assert_eq "chart_name reads name" "adopted-cluster" "$(chart_name "$tmpchart")"
assert_eq "chart_version reads version" "1.0.2" "$(chart_version "$tmpchart")"
assert_eq "template_name combines both" "adopted-cluster-1-0-2" "$(template_name "$tmpchart")"
rm -rf "$(dirname "$tmpchart")"

# ── require_env ──────────────────────────────────────────────────────────────
out=$(SOME_VAR="" bash -c "source '$SCRIPTS_DIR/lib/common.sh'; require_env SOME_VAR" 2>&1)
assert_eq "require_env fails on an unset var" 1 "$?"
assert_contains "names the missing var" "$out" "SOME_VAR"

SOME_VAR="a value" bash -c "source '$SCRIPTS_DIR/lib/common.sh'; require_env SOME_VAR" >/dev/null 2>&1
assert_eq "require_env passes when set" 0 "$?"

# ── require_cmd ──────────────────────────────────────────────────────────────
out=$(bash -c "source '$SCRIPTS_DIR/lib/common.sh'; require_cmd definitely-not-a-real-binary" 2>&1)
assert_eq "require_cmd fails on a missing binary" 1 "$?"
assert_contains "suggests deps.sh" "$out" "deps.sh"

finish

# ── Adopted cluster ──────────────────────────────────────────────────────────
# The two kubeconfigs are the reason for the adopted mode: one for the harness
# on the host, one for KCM inside the docker network. If they ever collapse
# into one, macOS goes blind again.
# unset first: this process already sourced common.sh, which exports it, and
# the child would inherit rather than derive.
assert_contains "the adopted container is named per run" \
    "$(RUN_ID=x bash -c "unset ADOPTED_CLUSTER_NAME; source '$SCRIPTS_DIR/lib/common.sh'; echo \$ADOPTED_CLUSTER_NAME")" \
    "adopted-x"
assert_eq "its API port differs from the management one" "1" \
    "$([[ "$ADOPTED_API_PORT" != "$MGMT_API_PORT" ]] && echo 1 || echo 0)"

# deploy_adopted_cluster.sh writes the host-facing kubeconfig at 127.0.0.1 and
# the internal one at the container name; grep the script rather than run it.
adopted_script="$SCRIPTS_DIR/deploy_adopted_cluster.sh"
assert_contains "the harness kubeconfig points at 127.0.0.1" \
    "$(grep -A2 'for the harness' "$adopted_script" || true)" "127.0.0.1"
# By IP, not hostname: the k0s API certificate has no SAN for the container
# name, so sveltos would fail the TLS check.
assert_contains "the KCM kubeconfig points at the container IP" \
    "$(grep 'ADOPTED_IP:6443' "$adopted_script" || true)" "ADOPTED_IP"
