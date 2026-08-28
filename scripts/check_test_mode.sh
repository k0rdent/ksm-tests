#!/bin/bash
set -euo pipefail

# Guard against typos in TEST_MODE before anything expensive happens.
# Extend ALLOWED_TEST_MODES as new provider scenarios are added.

ALLOWED_TEST_MODES="adopted"

if [[ ! " $ALLOWED_TEST_MODES " == *" ${TEST_MODE:-} "* ]]; then
  echo "❌ Invalid TEST_MODE='${TEST_MODE:-}'"
  echo "Allowed values: ${ALLOWED_TEST_MODES// /, }"
  echo "Hint: 'unset TEST_MODE' if it is left over from another project."
  exit 1
fi
