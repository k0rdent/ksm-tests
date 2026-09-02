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
# KCM=<id> is the shorthand CI uses too; ids come from
# scripts/config/kcm-variants.yaml and `make scenarios` lists them.
# export KCM="src-main"                 # or rel-1-11-0, rel-1-10-0
#
# Setting these directly still wins over the variant, for an ad-hoc version:
# export KCM_MODE="release"             # or source
# export KCM_VERSION="1.11.0"           # chart version, release mode
# export KCM_RELEASE_URL="oci://ghcr.io/k0rdent/kcm/charts/kcm"

# Source mode: any repository (a fork works) at any branch, tag or commit.
# export KCM_SRC_URL="https://github.com/K0rdent/kcm.git"
# export KCM_REF="main"

# ...or point at a checkout you are already working in (skips the clone).
# Do not share it between parallel source-mode runs -- the build writes into it.
# export KCM_SRC_DIR="$HOME/src/kcm"

# ── Running several e2e at once ──────────────────────────────────────────────
# Any non-empty value isolates this run: container names, host ports, workdir,
# kubeconfigs, image tags, cluster name and the MCS selector label.
# export RUN_ID="mine"

# ── Scope of the run ─────────────────────────────────────────────────────────
# export TEST_MODE="docker"
# export CLUSTER_NAME_SUFFIX="e2e"      # ClusterDeployment is <TEST_MODE>-<suffix>

# Providers KCM will actually install. Trimming this list is the main lever on
# install time -- each extra provider is another Helm chart to reconcile.
# export KCM_PROVIDERS="cluster-api-provider-docker cluster-api-provider-k0sproject-k0smotron projectsveltos"
# export KCM_CLUSTER_TEMPLATES="docker-hosted-cp"

# ── Scenario (services deployed through a MultiClusterService) ───────────────
# A scenario is a file in test_scenarios/. Run `make scenarios` for the list.
# export SCENARIO="01_basic"
# export SERVICES_FILE="$PWD/test_scenarios/01_basic.yaml"   # or a file of your own
# export SKIP_SERVICE_TEST="true"        # skip the ServiceTemplate/MCS steps

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
