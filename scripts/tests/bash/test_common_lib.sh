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
assert_eq "TEST_MODE defaults to docker" "docker" "$TEST_MODE"
assert_eq "CLD_NAME is <mode>-<suffix>" "docker-e2e" "$CLD_NAME"
assert_contains "CAPD provider is enabled by default" "$KCM_PROVIDERS" "cluster-api-provider-docker"
assert_contains "k0smotron is enabled (docker-hosted-cp needs it)" "$KCM_PROVIDERS" "cluster-api-provider-k0sproject-k0smotron"
assert_contains "sveltos is enabled" "$KCM_PROVIDERS" "projectsveltos"
assert_not_contains "aws provider is off" "$KCM_PROVIDERS" "cluster-api-provider-aws"
assert_not_contains "azure provider is off" "$KCM_PROVIDERS" "cluster-api-provider-azure"
assert_eq "registry URL matches the registry name" "oci://$REGISTRY_NAME:5000/charts" "$TEMPLATES_REPO_URL"

# ── chart helpers ────────────────────────────────────────────────────────────
tmpchart="$(mktemp -d)/mychart"
mkdir -p "$tmpchart"
cat > "$tmpchart/Chart.yaml" <<'EOF'
apiVersion: v2
name: docker-hosted-cp
description: |
  version: 9.9.9 should not be picked up from an indented line
type: application
version: 1.0.15
appVersion: "v1.36.1+k0s.0"
EOF
assert_eq "chart_name reads name" "docker-hosted-cp" "$(chart_name "$tmpchart")"
assert_eq "chart_version reads version" "1.0.15" "$(chart_version "$tmpchart")"
assert_eq "template_name combines both" "docker-hosted-cp-1-0-15" "$(template_name "$tmpchart")"
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
