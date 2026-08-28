#!/bin/bash
# RUN_ID must isolate everything two parallel runs could collide on.
# shellcheck source=scripts/tests/bash/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# names_for RUN_ID -- print the collision-prone values for one run.
names_for() {
    RUN_ID="$1" bash -c "
        source '$SCRIPTS_DIR/lib/common.sh'
        echo \"\$MGMT_CLUSTER_NAME|\$REGISTRY_NAME|\$WORKDIR|\$KUBECONFIG_MGMT|\$KUBECONFIG_CHILD|\$IMG|\$IMG_TELEMETRY|\$CLD_NAME|\$CLD_GROUP_LABEL|\$LOG_DIR\"
    "
}

a="$(names_for a)"
b="$(names_for b)"

IFS='|' read -ra fa <<< "$a"
IFS='|' read -ra fb <<< "$b"
labels=(MGMT_CLUSTER_NAME REGISTRY_NAME WORKDIR KUBECONFIG_MGMT KUBECONFIG_CHILD \
        IMG IMG_TELEMETRY CLD_NAME CLD_GROUP_LABEL LOG_DIR)

for i in "${!labels[@]}"; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${fa[$i]}" != "${fb[$i]}" ]]; then
        echo "  ✓ ${labels[$i]} differs between runs"
    else
        echo "  ✗ ${labels[$i]} collides: ${fa[$i]}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done

# Tools are deliberately shared -- re-downloading them per run would be waste.
bin_a="$(RUN_ID=a bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$BIN_DIR")"
bin_b="$(RUN_ID=b bash -c "source '$SCRIPTS_DIR/lib/common.sh'; echo \$BIN_DIR")"
assert_eq "BIN_DIR is shared between runs" "$bin_a" "$bin_b"

# Without RUN_ID the plain names stay, so a single run is unchanged.
plain="$(names_for '')"
assert_contains "no RUN_ID keeps the plain cluster name" "$plain" "kcm-mgmt|"
assert_contains "no RUN_ID keeps the plain registry name" "$plain" "kcm-test-registry|"
assert_contains "no RUN_ID keeps the plain kubeconfig" "$plain" "/kcfg_k0rdent|"
assert_contains "no RUN_ID keeps the default cluster name" "$plain" "adopted-e2e|"

finish
