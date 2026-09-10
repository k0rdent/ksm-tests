#!/bin/bash
set -euo pipefail

# Remove the services a SCENARIO_KEEP=true run left behind, running the same
# teardown assertions scenario_run.sh would have.
#
#   export SCENARIO=01_basic            # the same one, or it looks for the
#   ./scripts/scenario_clean.sh         # wrong MultiClusterService

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$SCRIPTS_DIR/lib/k8s.sh"

check_scenario
require_cluster
ensure_workdir

"$SCRIPTS_DIR/remove_services.sh"
