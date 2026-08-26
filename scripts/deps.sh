#!/bin/bash
set -euo pipefail

# Make sure every CLI the test scripts need is available.
#
# Tools that are already on PATH are left alone; anything missing is downloaded
# into .work/bin, which scripts/lib/common.sh prepends to PATH. Set
# FORCE_INSTALL_DEPS=1 to install the pinned versions regardless.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KUBECTL_VERSION="${KUBECTL_VERSION:-v1.35.0}"
HELM_VERSION="${HELM_VERSION:-v3.21.3}"
YQ_VERSION="${YQ_VERSION:-v4.53.3}"
JQ_VERSION="${JQ_VERSION:-1.7.1}"

FORCE_INSTALL_DEPS="${FORCE_INSTALL_DEPS:-0}"

ensure_workdir

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *)      die "Unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)             die "Unsupported architecture: $(uname -m)" ;;
esac

# needs_install CMD -- true when the tool must be downloaded.
needs_install() {
    [[ "$FORCE_INSTALL_DEPS" == "1" ]] && return 0
    ! command -v "$1" >/dev/null 2>&1
}

download() { # download URL DEST
    curl -fsSL "$1" -o "$2"
}

step "Checking host prerequisites"
# These are too intrusive to install automatically -- fail loudly instead.
for cmd in docker git make go curl tar; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "'$cmd' is required but not installed. Install it and re-run."
done
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon."
log "docker, git, make, go, curl, tar are present"

step "Checking test tooling"

if needs_install kubectl; then
    log "Installing kubectl $KUBECTL_VERSION into $BIN_DIR"
    download "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl" "$BIN_DIR/kubectl"
    chmod +x "$BIN_DIR/kubectl"
else
    log "kubectl: $(command -v kubectl)"
fi

if needs_install helm; then
    log "Installing helm $HELM_VERSION into $BIN_DIR"
    tmp="$(mktemp -d)"
    download "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz" "$tmp/helm.tar.gz"
    tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
    mv "$tmp/$OS-$ARCH/helm" "$BIN_DIR/helm"
    chmod +x "$BIN_DIR/helm"
    rm -rf "$tmp"
else
    log "helm: $(command -v helm)"
fi

# Several unrelated tools are called "yq". We need mikefarah's Go one; the
# python wrapper takes the same expressions but emits JSON, which silently
# changes the manifests we generate.
is_mikefarah_yq() {
    command -v yq >/dev/null 2>&1 || return 1
    yq --version 2>&1 | grep -qi mikefarah
}

if needs_install yq || ! is_mikefarah_yq; then
    if command -v yq >/dev/null 2>&1 && ! is_mikefarah_yq; then
        log "yq at $(command -v yq) is not mikefarah/yq -- installing our own"
    fi
    log "Installing yq $YQ_VERSION into $BIN_DIR"
    download "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_${OS}_${ARCH}" "$BIN_DIR/yq"
    chmod +x "$BIN_DIR/yq"
    hash -r
    is_mikefarah_yq || die "yq on PATH is still not mikefarah/yq: $(command -v yq)"
else
    log "yq: $(command -v yq)"
fi

if needs_install jq; then
    log "Installing jq $JQ_VERSION into $BIN_DIR"
    download "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-${OS}-${ARCH}" "$BIN_DIR/jq"
    chmod +x "$BIN_DIR/jq"
else
    log "jq: $(command -v jq)"
fi

# envsubst ships with GNU gettext; on macOS it comes from `brew install gettext`.
command -v envsubst >/dev/null 2>&1 \
    || die "'envsubst' is required (Debian/Ubuntu: apt-get install gettext-base, macOS: brew install gettext)."

step "Versions"
kubectl version --client 2>/dev/null | head -1
helm version --short
yq --version
jq --version

ok "All dependencies are available"
