#!/bin/bash
# Shared config and helpers. Sourcing must stay side-effect free apart from
# setting variables -- the unit tests source this directly.

# Resolved from this file, so scripts work from any working directory.
KCMT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$KCMT_LIB_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
CONFIG_DIR="$SCRIPTS_DIR/config"
export PROJECT_ROOT SCRIPTS_DIR CONFIG_DIR

# ── Output helpers ───────────────────────────────────────────────────────────
# Defined first because the validation below can fail.

log() { echo "   $*"; }

step() { echo -e "\n▶ $*"; }

ok() { echo "✅ $*"; }

warn() { echo "⚠️  $*" >&2; }

die() {
    echo "❌ $*" >&2
    exit 1
}

# ── Which k0rdent ────────────────────────────────────────────────────────────
# KCM names the environment as well as the build: the cluster is k0rdent-$KCM
# and its kubeconfig kcfg_k0rdent_$KCM, so several can exist side by side.
#
# deploy_k0rdent.sh and remove_k0rdent.sh require it. The scenario scripts do
# not: they run against ./kcfg_k0rdent, whoever wrote it -- this harness or a
# cluster you built yourself.
KCM="${KCM:-}"

# release -- install a published chart (tests what users get). Needs no git:
#            the Release and template manifests come from the kcm-templates
#            chart in the same registry.
# source  -- build the images and charts from a git checkout (tests a PR/main)
KCM_MODE="${KCM_MODE:-release}"
case "$KCM_MODE" in
    source|release) ;;
    *) die "Invalid KCM_MODE='$KCM_MODE'. Allowed values: release, source" ;;
esac

# The registry, not one chart in it: kcm, kcm-templates and every provider
# chart sit side by side, so a staging build is just a different OCI_URL.
OCI_URL="${OCI_URL:-oci://ghcr.io/k0rdent/kcm/charts}"
SRC_URL="${SRC_URL:-https://github.com/K0rdent/kcm.git}"
export OCI_URL SRC_URL

# KCM is the chart version in release mode and the git ref in source mode.
# KCM_VERSION and KCM_REF are what the scripts read; KCM only sets them.
if [[ -n "$KCM" ]]; then
    if [[ "$KCM_MODE" == "source" ]]; then
        # Any branch, tag or commit. No shape to check -- a branch is a name.
        KCM_REF="${KCM_REF:-$KCM}"
    elif [[ "$KCM" == [0-9]* ]]; then
        KCM_VERSION="${KCM_VERSION:-$KCM}"
    else
        # Left alone this would fail much later, on a chart that does not exist.
        die "KCM='$KCM' is not a chart version: it must start with a digit.
For a branch, tag or commit add KCM_MODE=source."
    fi
fi
KCM_VERSION="${KCM_VERSION:-}"
export KCM KCM_MODE KCM_VERSION

# ── Working directories ──────────────────────────────────────────────────────
# Build state belongs to one cluster; the rendered scenario manifests do not --
# they are transient, and the scenario scripts have no KCM to key them by.
WORKDIR="${WORKDIR:-$PROJECT_ROOT/.work}"
ENVDIR="${ENVDIR:-$WORKDIR/k0rdent-$KCM}"
# Tools are shared between environments.
BIN_DIR="${BIN_DIR:-$PROJECT_ROOT/.bin}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
export WORKDIR ENVDIR BIN_DIR LOG_DIR

# Tools installed by deps.sh take precedence over anything on the system.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) PATH="$BIN_DIR:$PATH" ;;
esac
export PATH

# ── KCM checkout (source mode only) ──────────────────────────────────────────
KCM_REF="${KCM_REF:-main}"
# Point KCM_SRC_DIR at an existing checkout to test local changes without
# cloning. Not safe to share between environments -- the build writes into it.
KCM_SRC_DIR="${KCM_SRC_DIR:-}"
if [[ -n "$KCM_SRC_DIR" ]]; then
    KCM_DIR="$KCM_SRC_DIR"
else
    KCM_DIR="$ENVDIR/kcm"
fi
export KCM_REF KCM_SRC_DIR KCM_DIR

# ── Images (source mode only) ────────────────────────────────────────────────
# Tagged per environment so two builds do not overwrite each other.
IMG="${IMG:-localhost/kcm/controller:${KCM:-latest}}"
IMG_TELEMETRY="${IMG_TELEMETRY:-localhost/kcm/telemetry:${KCM:-latest}}"
export IMG IMG_TELEMETRY

# ── Clusters (k0s in Docker) ─────────────────────────────────────────────────
MGMT_CLUSTER_NAME="${MGMT_CLUSTER_NAME:-k0rdent-$KCM}"
MGMT_API_PORT="${MGMT_API_PORT:-6443}"
K0S_IMAGE="${K0S_IMAGE:-docker.io/k0sproject/k0s:v1.36.3-k0s.0}"
# Shared with the local registry so KCM can reach it by container name.
# Several environments share it too: the names are unique.
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
export MGMT_CLUSTER_NAME MGMT_API_PORT K0S_IMAGE DOCKER_NETWORK

# ── Local OCI registry for the template charts (source mode only) ────────────
REGISTRY_NAME="${REGISTRY_NAME:-kcm-registry-$KCM}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
# deploy_registry.sh may pick a different free port and record it in
# $ENVDIR/registry.env, which push_kcm_artifacts.sh then sources.
REGISTRY_REPO="${REGISTRY_REPO:-oci://127.0.0.1:$REGISTRY_PORT/charts}"
if [[ "$KCM_MODE" == "release" ]]; then
    TEMPLATES_REPO_URL="${TEMPLATES_REPO_URL:-$OCI_URL}"
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
# self -- KCM deploys the services into the cluster it runs in, so there is one
# cluster, no ClusterDeployment and nothing to adopt.
TEST_MODE="${TEST_MODE:-self}"
case "$TEST_MODE" in
    self) ;;
    *) die "Invalid TEST_MODE='$TEST_MODE'. Allowed values: self
Hint: 'unset TEST_MODE' if it is left over from another project." ;;
esac

# The scenario scripts read this one, and only this one. deploy_k0rdent.sh
# writes the cluster's kubeconfig to both names, so switching environments is
# a matter of pointing kcfg_k0rdent at another kcfg_k0rdent_<KCM>.
KUBECONFIG_MGMT="${KUBECONFIG_MGMT:-$PROJECT_ROOT/kcfg_k0rdent}"
KUBECONFIG_NAMED="${KUBECONFIG_NAMED:-$PROJECT_ROOT/kcfg_k0rdent_$KCM}"
# Kept as its own name so the scripts still read "child" where they check what
# was deployed; under self-management it is the same cluster.
KUBECONFIG_CHILD="${KUBECONFIG_CHILD:-$KUBECONFIG_MGMT}"
export NAMESPACE KCM_HELM_RELEASE_NAME TEST_MODE
export KUBECONFIG_MGMT KUBECONFIG_NAMED KUBECONFIG_CHILD

# ── What KCM actually installs ───────────────────────────────────────────────
# Only these stay in the Release and Management; every provider dropped is a
# Helm chart KCM need not reconcile, which is most of the install time. Under
# self-management nothing is provisioned at all, so sveltos is the whole list
# and no cluster template is needed.
KCM_PROVIDERS="${KCM_PROVIDERS:-projectsveltos}"
KCM_CLUSTER_TEMPLATES="${KCM_CLUSTER_TEMPLATES:-}"
export KCM_PROVIDERS KCM_CLUSTER_TEMPLATES

KSM_PROVIDER="${KSM_PROVIDER:-ksm-projectsveltos}"
export KSM_PROVIDER

# ── Scenario under test ──────────────────────────────────────────────────────
# A scenario is a file in test_scenarios/ describing the services and their
# dependencies. SCENARIO picks one by filename stem; SERVICES_FILE overrides
# the path outright.
SCENARIOS_DIR="${SCENARIOS_DIR:-$PROJECT_ROOT/test_scenarios}"
SCENARIO="${SCENARIO:-01_basic}"
SERVICES_FILE="${SERVICES_FILE:-$SCENARIOS_DIR/$SCENARIO.yaml}"
# Scenario stems use underscores, which RFC 1123 forbids in object names.
SCENARIO_SLUG="${SCENARIO//_/-}"
MCS_NAME="${MCS_NAME:-mcs-$SCENARIO_SLUG}"
export SCENARIOS_DIR SCENARIO SCENARIO_SLUG SERVICES_FILE MCS_NAME

# ── Timeouts (seconds) ───────────────────────────────────────────────────────
MANAGEMENT_TIMEOUT="${MANAGEMENT_TIMEOUT:-1500}"   # 25 min
TEMPLATES_TIMEOUT="${TEMPLATES_TIMEOUT:-900}"      # 15 min
PODS_TIMEOUT="${PODS_TIMEOUT:-900}"                # 15 min
MCS_TIMEOUT="${MCS_TIMEOUT:-900}"                  # 15 min
export MANAGEMENT_TIMEOUT TEMPLATES_TIMEOUT PODS_TIMEOUT MCS_TIMEOUT

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

# require_kcm -- the environment scripts cannot guess which cluster is meant.
require_kcm() {
    [[ -n "$KCM" ]] && return 0
    die "KCM is required: it names the cluster (k0rdent-<KCM>) as well as the build.
  export KCM=1.11.0                     # a published chart version
  export KCM=main KCM_MODE=source       # a branch, tag or commit"
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

# built_field KEY [FILE] -- one value out of a kcm-build.env, empty if absent.
# Read, never sourced: it is data, and a value with spaces would otherwise
# become a command.
built_field() {
    local file="${2:-$ENVDIR/kcm-build.env}"
    [[ -f "$file" ]] || return 0
    sed -n "s/^$1='\(.*\)'\$/\1/p; s/^$1=\([^']*\)\$/\1/p" "$file" 2>/dev/null | head -1
}

# list_scenarios -- one scenario stem per line, sorted.
list_scenarios() {
    local f
    for f in "$SCENARIOS_DIR"/*.yaml; do
        [[ -e "$f" ]] || continue
        basename "$f" .yaml
    done | sort
}

# check_scenario -- a typo should say what is available, not just refuse.
check_scenario() {
    [[ -f "$SERVICES_FILE" ]] && return 0
    die "Unknown scenario '$SCENARIO' (no $SERVICES_FILE).
Available: $(list_scenarios | tr '\n' ' ')"
}

# ── Filesystem helpers ───────────────────────────────────────────────────────

ensure_workdir() {
    mkdir -p "$WORKDIR" "$ENVDIR" "$BIN_DIR"
}

# The generated Release / Template manifests produced by `make templates-generate`.
# In release mode these come from the kcm-templates chart pulled into the
# environment directory; in source mode from the checkout, where the build
# regenerates them.
kcm_chart_root() {
    if [[ "$KCM_MODE" == "release" ]]; then
        echo "$ENVDIR/kcm-templates"
    else
        echo "$KCM_DIR/templates/provider/kcm-templates"
    fi
}

kcm_templates_dir() {
    echo "$(kcm_chart_root)/files/templates"
}

kcm_release_file() {
    echo "$(kcm_chart_root)/files/release.yaml"
}
