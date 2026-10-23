#!/usr/bin/env bash
set -euo pipefail

# Are the provider credentials usable? Run this before anything is built: the
# environment takes about five minutes to come up, and finding out afterwards
# that a secret is missing wastes all of it. k0rdent/catalog puts the same
# check first in its jobs for the same reason.
#
# It is also the check that keeps a bad run from becoming an expensive one:
# with credentials the provider rejects, k0rdent still creates the
# ClusterDeployment, the infra provider cannot reach the API, and the cluster
# can then no longer be deleted either -- its finalizers wait on calls that
# will never succeed.
#
# A no-op unless TEST_MODE names a provider, so it can sit in the pipeline
# always.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

if ! is_cloud_mode; then
    log "TEST_MODE=$TEST_MODE -- no provider credentials needed"
    exit 0
fi

# Which variables the mode needs, and the provider CLI check itself, are both
# catalog's -- see scripts/catalog/README.md. -x reports every missing one at
# once instead of dying on the first unbound variable.
step "Checking the $TEST_MODE credentials"
"$SCRIPTS_DIR/catalog/check_test_mode.sh" -x
"$SCRIPTS_DIR/catalog/check_${TEST_MODE}_creds.sh"

ok "The $TEST_MODE credentials work"
