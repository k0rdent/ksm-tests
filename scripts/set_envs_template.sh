#!/bin/bash
# Template for local runs. Copy it, adjust, and source it:
#
#   cp scripts/set_envs_template.sh set_envs.sh
#   $EDITOR set_envs.sh
#   source set_envs.sh
#   ./scripts/deploy_k0rdent.sh
#
# set_envs.sh is gitignored. Everything here has a working default in
# scripts/lib/common.sh -- uncomment only what you want to change.

# ── Which KCM to test ────────────────────────────────────────────────────────
# Required by deploy_k0rdent.sh and remove_k0rdent.sh. It names the cluster
# (k0rdent-$KCM) as well as the build, so several can exist side by side.
# export KCM="1.12.0-rc.3"              # a published chart version
# export KCM_MODE="release"             # or source, to build from git
# export OCI_URL="oci://ghcr.io/k0rdent/kcm/charts"   # or .../staging

# Source mode: KCM is any branch, tag or commit, from any repository.
# export KCM="main"
# export KCM_MODE="source"
# export SRC_URL="https://github.com/K0rdent/kcm.git"

# ...or point at a checkout you are already working in (skips the clone).
# Do not share it between environments -- the build writes into it.
# export KCM_SRC_DIR="$HOME/src/kcm"

# ── Scope of the run ─────────────────────────────────────────────────────────
# export TEST_MODE="self"               # the only mode: KCM deploys into itself

# Providers KCM will actually install. Trimming this list is the main lever on
# install time -- each extra provider is another Helm chart to reconcile.
# export KCM_PROVIDERS="projectsveltos"
# export KCM_CLUSTER_TEMPLATES=""

# ── Scenario (services deployed through a MultiClusterService) ───────────────
# A scenario is a file in test_scenarios/. ./scripts/get_scenarios.sh lists them.
# export SCENARIO="01_basic"
# export SERVICES_FILE="$PWD/test_scenarios/01_basic.yaml"   # or a file of your own
# export SCENARIO_KEEP="true"           # leave the services running

# ── Environment names ────────────────────────────────────────────────────────
# export DOCKER_NETWORK="kind"
# export REGISTRY_PORT="5001"
# export MGMT_API_PORT="6443"

# ── Timeouts, in seconds ─────────────────────────────────────────────────────
# export MANAGEMENT_TIMEOUT="1500"

# ── Debugging ────────────────────────────────────────────────────────────────
# export DEBUG="true"                   # verbose helm output and pod describes
