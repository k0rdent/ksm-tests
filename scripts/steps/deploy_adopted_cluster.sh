#!/usr/bin/env bash
set -euo pipefail

# A second k0s cluster in Docker, handed to KCM as an adopted
# ClusterDeployment. The services then land on a cluster KCM reaches over the
# network rather than on the one it runs in.
#
# The objects are the three KCM's own config/dev/ manifests use -- Secret with
# the kubeconfig, Credential pointing at it, ClusterDeployment on the
# adopted-cluster ClusterTemplate -- rendered here so the label the
# MultiClusterService selects on can be put on the ClusterDeployment.
#
# A no-op unless TEST_MODE is adopted, so it can sit in the pipeline always.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/docker.sh
source "$SCRIPTS_DIR/lib/docker.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

if [[ "$TEST_MODE" != "adopted" ]]; then
    log "TEST_MODE=$TEST_MODE -- nothing to adopt"
    exit 0
fi

require_cmd docker kubectl
ensure_workdir

step "Deploying the cluster to adopt: '$ADOPTED_CLUSTER_NAME'"
ensure_network "$DOCKER_NETWORK"
start_k0s_container "$ADOPTED_CLUSTER_NAME" "$ADOPTED_API_PORT"
ADOPTED_API_PORT="$K0S_API_PORT"

# Two kubeconfigs for one cluster, because the two readers reach it by
# different routes: we talk to the published port on the host, KCM talks to the
# container by name on the shared docker network. Handing KCM the host one
# would point it at its own 127.0.0.1.
step "Writing kubeconfigs"
write_k0s_kubeconfig "$ADOPTED_CLUSTER_NAME" \
    "https://127.0.0.1:$ADOPTED_API_PORT" "$KUBECONFIG_ADOPTED"
log "host:    $KUBECONFIG_ADOPTED -> 127.0.0.1:$ADOPTED_API_PORT"

# By address, not by container name: k0s issues the API certificate for
# kubernetes, localhost and the node's IP, and nothing else. Sveltos reaches
# the name but then fails TLS verification on it, and the SveltosCluster sits
# Down with the services never deployed.
ADOPTED_IP="$(container_ip "$ADOPTED_CLUSTER_NAME" "$DOCKER_NETWORK")"
[[ -n "$ADOPTED_IP" ]] \
    || die "Container '$ADOPTED_CLUSTER_NAME' has no address on network '$DOCKER_NETWORK'"

INCLUSTER="$ENVDIR/adopted-kubeconfig.incluster.yaml"
write_k0s_kubeconfig "$ADOPTED_CLUSTER_NAME" "https://$ADOPTED_IP:6443" "$INCLUSTER"
log "in KCM:  $ADOPTED_IP:6443"

step "Waiting for the adopted cluster's node"
until KUBECONFIG="$KUBECONFIG_ADOPTED" kubectl get nodes --no-headers 2>/dev/null | grep -q .; do
    sleep 2
done
until KUBECONFIG="$KUBECONFIG_ADOPTED" kubectl wait -n kube-system \
    --for=condition=Ready pod --all --timeout=2s >/dev/null 2>&1; do
    sleep 5
done
# Single-node cluster: everything has to run on the control plane.
KUBECONFIG="$KUBECONFIG_ADOPTED" kubectl taint nodes "$ADOPTED_CLUSTER_NAME" \
    node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
KUBECONFIG="$KUBECONFIG_ADOPTED" kubectl get nodes

export KUBECONFIG="$KUBECONFIG_MGMT"
require_cluster

RELEASE_ENV="$ENVDIR/release.env"
[[ -f "$RELEASE_ENV" ]] || die "$RELEASE_ENV not found. Run ./scripts/steps/apply_release.sh first."
# shellcheck source=/dev/null
source "$RELEASE_ENV"
# The template the ClusterDeployment references, by the name apply_release.sh
# actually applied -- the version is in it, so it must not be guessed.
CLUSTER_TEMPLATE="$(tr ' ' '\n' <<< "${CLUSTER_TEMPLATES:-}" | grep '^adopted-cluster' | head -1)"
[[ -n "$CLUSTER_TEMPLATE" ]] \
    || die "No adopted-cluster ClusterTemplate was applied. KCM_CLUSTER_TEMPLATES='$KCM_CLUSTER_TEMPLATES'"

# Two manifests, not one: the ClusterDeployment admission webhook refuses a
# Credential that is not Ready yet, and `kubectl apply -f` of a single file
# creates all three in the same breath.
CREDENTIAL="$ENVDIR/adopted-credential.rendered.yaml"
cat > "$CREDENTIAL" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $ADOPTED_SECRET_NAME
  namespace: $NAMESPACE
  labels:
    k0rdent.mirantis.com/component: "kcm"
type: Opaque
data:
  value: $(base64 -w0 < "$INCLUSTER")
---
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Credential
metadata:
  name: $ADOPTED_CRED_NAME
  namespace: $NAMESPACE
spec:
  description: Adopted Credentials
  identityRef:
    apiVersion: v1
    kind: Secret
    name: $ADOPTED_SECRET_NAME
    namespace: $NAMESPACE
EOF

step "Creating the Credential for '$ADOPTED_CLUSTER_NAME'"
# Not the manifest: it carries the cluster's admin kubeconfig.
log "secret: $ADOPTED_SECRET_NAME, credential: $ADOPTED_CRED_NAME"
kube apply -f "$CREDENTIAL"

wait_for_ready Credential "$ADOPTED_CRED_NAME" "$NAMESPACE" "$MCS_TIMEOUT" \
    || die "Credential '$ADOPTED_CRED_NAME' never became ready"

MANIFEST="$ENVDIR/adopted-clusterdeployment.rendered.yaml"
cat > "$MANIFEST" <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: $ADOPTED_CLD_NAME
  namespace: $NAMESPACE
  labels:
    # What MultiClusterService.spec.clusterSelector matches.
    $ADOPTED_LABEL_KEY: $ADOPTED_LABEL_VALUE
spec:
  template: $CLUSTER_TEMPLATE
  credential: $ADOPTED_CRED_NAME
  config:
    clusterLabels: {}
    clusterAnnotations: {}
EOF

step "Creating the ClusterDeployment '$ADOPTED_CLD_NAME'"
log "template: $CLUSTER_TEMPLATE, label: $ADOPTED_LABEL_KEY=$ADOPTED_LABEL_VALUE"
kube apply -f "$MANIFEST"

step "Waiting for '$ADOPTED_CLD_NAME' to be adopted"
if ! wait_for_condition ClusterDeployment "$ADOPTED_CLD_NAME" "$NAMESPACE" Ready "$MCS_TIMEOUT"; then
    { kube get clusterdeployment "$ADOPTED_CLD_NAME" -n "$NAMESPACE" -o yaml
      kube get sveltoscluster -A
      kcm_errors 20m; } >&2
    die "ClusterDeployment '$ADOPTED_CLD_NAME' never became Ready"
fi

kube get clusterdeployment -n "$NAMESPACE"
ok "Adopted cluster '$ADOPTED_CLUSTER_NAME' is ready as '$ADOPTED_CLD_NAME'"
