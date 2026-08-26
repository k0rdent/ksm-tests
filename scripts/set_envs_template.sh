#!/bin/bash
# Template for local runs. Copy it, adjust, and source it:
#
#   cp scripts/set_envs_template.sh set_envs.sh
#   $EDITOR set_envs.sh
#   source set_envs.sh
#   ./scripts/e2e_test.sh
#
# set_envs.sh is gitignored. Everything here has a working default in
# scripts/lib/common.sh -- uncomment only what you want to change.

# ── Which KCM to test ────────────────────────────────────────────────────────
# Test a branch/tag/SHA from the upstream repository:
# export KCM_REPO="https://github.com/K0rdent/kcm.git"
# export KCM_REF="main"

# ...or point at a checkout you are already working in (skips the clone):
# export KCM_SRC_DIR="$HOME/src/kcm"

# ── Scope of the run ─────────────────────────────────────────────────────────
# export TEST_MODE="docker"
# export CLUSTER_NAME_SUFFIX="e2e"      # ClusterDeployment is <TEST_MODE>-<suffix>
# export WORKERS_NUMBER="1"

# Providers KCM will actually install. Trimming this list is the main lever on
# install time -- each extra provider is another Helm chart to reconcile.
# export KCM_PROVIDERS="cluster-api-provider-docker cluster-api-provider-k0sproject-k0smotron projectsveltos"
# export KCM_CLUSTER_TEMPLATES="docker-hosted-cp"

# ── Environment names ────────────────────────────────────────────────────────
# export MGMT_CLUSTER_NAME="kcm-mgmt"
# export DOCKER_NETWORK="kind"          # CAPD's default network; change with care
# export REGISTRY_NAME="kcm-test-registry"
# export REGISTRY_PORT="5001"
# export MGMT_API_PORT="6443"

# ── Timeouts, in seconds ─────────────────────────────────────────────────────
# export MANAGEMENT_TIMEOUT="1500"
# export CLD_TIMEOUT="1800"

# ── Debugging ────────────────────────────────────────────────────────────────
# export DEBUG="true"                   # verbose helm output and pod describes
