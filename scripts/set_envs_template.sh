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
# "source" builds the images and charts from a checkout; "release" installs the
# published chart from ghcr and needs neither Go nor a local registry.
# export KCM_SOURCE="source"
# export KCM_RELEASE_VERSION="1.11.0"

# Test a branch/tag/SHA from the upstream repository:
# export KCM_REPO="https://github.com/K0rdent/kcm.git"
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
# export WORKERS_NUMBER="1"

# Providers KCM will actually install. Trimming this list is the main lever on
# install time -- each extra provider is another Helm chart to reconcile.
# export KCM_PROVIDERS="cluster-api-provider-docker cluster-api-provider-k0sproject-k0smotron projectsveltos"
# export KCM_CLUSTER_TEMPLATES="docker-hosted-cp"

# ── Services deployed through a MultiClusterService ──────────────────────────
# The set is picked by SERVICE_SET: "traefik", or "kserve" for the
# cert-manager -> kserve-crd -> kserve-resources chain. Point SERVICES_FILE at
# your own file to test a different set.
# export SERVICE_SET="traefik"          # or "kserve"
# export SERVICES_FILE="$PWD/scripts/config/services-traefik.yaml"
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
