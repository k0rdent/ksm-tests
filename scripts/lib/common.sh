#!/bin/bash
# Shared config and helpers. Sourcing must stay side-effect free apart from
# setting variables -- the unit tests source this directly.

# Resolved from this file, so scripts work from any working directory.
KCMT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$KCMT_LIB_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
CONFIG_DIR="$SCRIPTS_DIR/config"
export PROJECT_ROOT SCRIPTS_DIR CONFIG_DIR

# ── Run isolation ────────────────────────────────────────────────────────────
# Set RUN_ID to run several e2e runs side by side. Everything that could
# collide -- container names, host ports, workdir, kubeconfigs, image tags and
# the cluster name -- is suffixed with it. Unset means the plain names, so a
# single run looks exactly as before.
RUN_ID="${RUN_ID:-}"
RUN_SUFFIX="${RUN_ID:+-$RUN_ID}"
export RUN_ID RUN_SUFFIX

# ── Working directory ────────────────────────────────────────────────────────
WORKDIR="${WORKDIR:-$PROJECT_ROOT/.work$RUN_SUFFIX}"
# Tools are shared between runs; only generated state is per-run.
BIN_DIR="${BIN_DIR:-$PROJECT_ROOT/.work/bin}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs$RUN_SUFFIX}"
export WORKDIR BIN_DIR LOG_DIR

# Tools installed by deps.sh take precedence over anything on the system.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) PATH="$BIN_DIR:$PATH" ;;
esac
export PATH

# ── What is under test ───────────────────────────────────────────────────────
# source  -- build the images and charts from a KCM checkout (tests a PR/main)
# release -- install the published chart from ghcr (tests what users get)
KCM_SOURCE="${KCM_SOURCE:-source}"
KCM_RELEASE_VERSION="${KCM_RELEASE_VERSION:-1.11.0}"
KCM_RELEASE_REPO="${KCM_RELEASE_REPO:-oci://ghcr.io/k0rdent/kcm/charts}"
export KCM_SOURCE KCM_RELEASE_VERSION KCM_RELEASE_REPO

# ── KCM checkout ─────────────────────────────────────────────────────────────
# Needed in both modes: it supplies the Release and template manifests. In
# release mode the checkout is pinned to the tag matching KCM_RELEASE_VERSION.
KCM_REPO="${KCM_REPO:-https://github.com/K0rdent/kcm.git}"
if [[ "$KCM_SOURCE" == "release" ]]; then
    KCM_REF="${KCM_REF:-v$KCM_RELEASE_VERSION}"
else
    KCM_REF="${KCM_REF:-main}"
fi
# Point KCM_SRC_DIR at an existing checkout to test local changes without
# cloning. Not safe to share between parallel source-mode runs -- the build
# writes into it.
KCM_SRC_DIR="${KCM_SRC_DIR:-}"
if [[ -n "$KCM_SRC_DIR" ]]; then
    KCM_DIR="$KCM_SRC_DIR"
else
    KCM_DIR="$WORKDIR/kcm"
fi
export KCM_REPO KCM_REF KCM_SRC_DIR KCM_DIR

# ── Images (source mode only) ────────────────────────────────────────────────
# Tagged per run so parallel builds do not overwrite each other.
IMG="${IMG:-localhost/kcm/controller:${RUN_ID:-latest}}"
IMG_TELEMETRY="${IMG_TELEMETRY:-localhost/kcm/telemetry:${RUN_ID:-latest}}"
export IMG IMG_TELEMETRY

# ── Management cluster (k0s in Docker) ───────────────────────────────────────
MGMT_CLUSTER_NAME="${MGMT_CLUSTER_NAME:-kcm-mgmt$RUN_SUFFIX}"
MGMT_API_PORT="${MGMT_API_PORT:-6443}"
K0S_IMAGE="${K0S_IMAGE:-docker.io/k0sproject/k0s:v1.36.3-k0s.0}"
# CAPD creates the workload-cluster containers on the "kind" network by default,
# so the management cluster has to live there too. Parallel runs share it:
# cluster names are unique, so their containers never collide.
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
export MGMT_CLUSTER_NAME MGMT_API_PORT K0S_IMAGE DOCKER_NETWORK

# ── Local OCI registry for the template charts (source mode only) ────────────
REGISTRY_NAME="${REGISTRY_NAME:-kcm-test-registry$RUN_SUFFIX}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
# deploy_registry.sh may pick a different free port and record it in
# $WORKDIR/registry.env, which push_kcm_artifacts.sh then sources.
REGISTRY_REPO="${REGISTRY_REPO:-oci://127.0.0.1:$REGISTRY_PORT/charts}"
if [[ "$KCM_SOURCE" == "release" ]]; then
    TEMPLATES_REPO_URL="${TEMPLATES_REPO_URL:-$KCM_RELEASE_REPO}"
    INSECURE_REGISTRY="${INSECURE_REGISTRY:-false}"
else
    TEMPLATES_REPO_URL="${TEMPLATES_REPO_URL:-oci://$REGISTRY_NAME:5000/charts}"
    INSECURE_REGISTRY="${INSECURE_REGISTRY:-true}"
fi
export REGISTRY_NAME REGISTRY_PORT REGISTRY_IMAGE REGISTRY_REPO
export TEMPLATES_REPO_URL INSECURE_REGISTRY

# ── Kubernetes ───────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-kcm-system}"
KCM_HELM_RELEASE_NAME="${KCM_HELM_RELEASE_NAME:-kcm}"
TEST_MODE="${TEST_MODE:-docker}"
KUBECONFIG_MGMT="${KUBECONFIG_MGMT:-$PROJECT_ROOT/kcfg_k0rdent$RUN_SUFFIX}"
KUBECONFIG_CHILD="${KUBECONFIG_CHILD:-$PROJECT_ROOT/kcfg_$TEST_MODE$RUN_SUFFIX}"
export NAMESPACE KCM_HELM_RELEASE_NAME TEST_MODE KUBECONFIG_MGMT KUBECONFIG_CHILD

# ── What KCM actually installs ───────────────────────────────────────────────
# Only these providers stay in the Release and Management; every one dropped is
# a Helm chart KCM need not reconcile, which is most of the install time.
# docker-hosted-cp requires CAPD + k0smotron (control plane and bootstrap).
KCM_PROVIDERS="${KCM_PROVIDERS:-cluster-api-provider-docker cluster-api-provider-k0sproject-k0smotron projectsveltos}"
KCM_CLUSTER_TEMPLATES="${KCM_CLUSTER_TEMPLATES:-docker-hosted-cp}"
export KCM_PROVIDERS KCM_CLUSTER_TEMPLATES

# ── ClusterDeployment under test ─────────────────────────────────────────────
CLUSTER_NAME_SUFFIX="${CLUSTER_NAME_SUFFIX:-${RUN_ID:-e2e}}"
CLD_NAME="${CLD_NAME:-$TEST_MODE-$CLUSTER_NAME_SUFFIX}"
WORKERS_NUMBER="${WORKERS_NUMBER:-1}"
# MCS selects the cluster by this label, set on the ClusterDeployment. It is
# per-run so a MultiClusterService never reaches another run's cluster.
CLD_GROUP_LABEL="${CLD_GROUP_LABEL:-e2e-${RUN_ID:-default}}"
export CLUSTER_NAME_SUFFIX CLD_NAME WORKERS_NUMBER CLD_GROUP_LABEL

# ── Service under test (traefik via ServiceTemplate + MultiClusterService) ───
SERVICE_NAME="${SERVICE_NAME:-traefik}"
SERVICE_CHART="${SERVICE_CHART:-traefik}"
SERVICE_CHART_VERSION="${SERVICE_CHART_VERSION:-41.2.0}"
SERVICE_HELM_REPO="${SERVICE_HELM_REPO:-https://traefik.github.io/charts}"
SERVICE_NAMESPACE="${SERVICE_NAMESPACE:-traefik}"
export SERVICE_NAME SERVICE_CHART SERVICE_CHART_VERSION SERVICE_HELM_REPO SERVICE_NAMESPACE

# ── Timeouts (seconds) ───────────────────────────────────────────────────────
MANAGEMENT_TIMEOUT="${MANAGEMENT_TIMEOUT:-1500}"   # 25 min
TEMPLATES_TIMEOUT="${TEMPLATES_TIMEOUT:-900}"      # 15 min
CLD_TIMEOUT="${CLD_TIMEOUT:-1800}"                 # 30 min
CLD_REMOVAL_TIMEOUT="${CLD_REMOVAL_TIMEOUT:-900}"  # 15 min
PODS_TIMEOUT="${PODS_TIMEOUT:-900}"                # 15 min
MCS_TIMEOUT="${MCS_TIMEOUT:-900}"                  # 15 min
export MANAGEMENT_TIMEOUT TEMPLATES_TIMEOUT CLD_TIMEOUT CLD_REMOVAL_TIMEOUT
export PODS_TIMEOUT MCS_TIMEOUT

# ── Output helpers ───────────────────────────────────────────────────────────

log() { echo "   $*"; }

step() { echo -e "\n▶ $*"; }

ok() { echo "✅ $*"; }

warn() { echo "⚠️  $*" >&2; }

die() {
    echo "❌ $*" >&2
    exit 1
}

# ── Assertions ───────────────────────────────────────────────────────────────

# require_env VAR [VAR...] -- fail unless every named variable is set & non-empty.
require_env() {
    local missing=()
    local var
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required environment variable(s): ${missing[*]}"
    fi
}

# require_yq -- several unrelated tools are called "yq"; we need mikefarah's.
# The python one accepts the same expressions but emits JSON and rejects -i.
require_yq() {
    require_cmd yq
    yq --version 2>&1 | grep -qi mikefarah \
        || die "yq at $(command -v yq) is not mikefarah/yq. Run ./scripts/deps.sh"
}

# require_cmd CMD [CMD...] -- fail unless every command is on PATH.
require_cmd() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required command(s): ${missing[*]}. Run ./scripts/deps.sh"
    fi
}

# ── Portability ──────────────────────────────────────────────────────────────

# b64decode -- decode stdin. GNU base64 wants --decode, BSD/macOS wants -D.
b64decode() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

# ── Version helpers ──────────────────────────────────────────────────────────

# fqdn_version 1.11.0 -> 1-11-0 ; v1.11.0 -> 1-11-0
# KCM uses this form for object names (Release "kcm-1-11-0", templates, ...).
fqdn_version() {
    local version="${1:?fqdn_version needs a version}"
    version="${version#v}"
    echo "${version//./-}"
}

# yaml_top_scalar FILE KEY -- value of a top-level (unindented) scalar key.
# Deliberately grep-based so it works before deps.sh has installed yq.
yaml_top_scalar() {
    local file="${1:?yaml_top_scalar needs a file}"
    local key="${2:?yaml_top_scalar needs a key}"
    [[ -f "$file" ]] || die "No such file: $file"
    awk -v k="^$key:" '$0 ~ k { print $2; exit }' "$file"
}

# chart_name CHART_DIR / chart_version CHART_DIR -- read from Chart.yaml.
# Same extraction the KCM hack/templates.sh uses, so the names line up.
chart_name() { yaml_top_scalar "${1:?chart_name needs a chart dir}/Chart.yaml" name; }
chart_version() { yaml_top_scalar "${1:?chart_version needs a chart dir}/Chart.yaml" version; }

# template_name CHART_DIR -> "<chart name>-<version with dashes>", e.g.
# docker-hosted-cp-1-0-15. Never hardcode these; charts get bumped often.
template_name() {
    local dir="${1:?template_name needs a chart dir}"
    echo "$(chart_name "$dir")-$(fqdn_version "$(chart_version "$dir")")"
}

# service_template_name -> e.g. traefik-41-2-0. Same naming KCM uses for
# ServiceTemplates, so it matches what a MultiClusterService references.
service_template_name() {
    echo "$SERVICE_CHART-$(fqdn_version "$SERVICE_CHART_VERSION")"
}

# check_kcm_source -- guard against a typo in KCM_SOURCE.
check_kcm_source() {
    case "$KCM_SOURCE" in
        source|release) ;;
        *) die "Invalid KCM_SOURCE='$KCM_SOURCE'. Allowed values: source, release" ;;
    esac
}

# ── Filesystem helpers ───────────────────────────────────────────────────────

ensure_workdir() {
    mkdir -p "$WORKDIR" "$BIN_DIR"
}

# The generated Release / Template manifests produced by `make templates-generate`.
kcm_templates_dir() {
    echo "$KCM_DIR/templates/provider/kcm-templates/files/templates"
}

kcm_release_file() {
    echo "$KCM_DIR/templates/provider/kcm-templates/files/release.yaml"
}
