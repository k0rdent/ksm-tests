#!/bin/bash
set -euo pipefail

# Guard against typos in TEST_MODE before anything expensive happens.
# Extend ALLOWED_TEST_MODES as new provider scenarios are added.

ALLOWED_TEST_MODES="docker"

if [[ ! " $ALLOWED_TEST_MODES " == *" ${TEST_MODE:-} "* ]]; then
  echo "❌ Invalid TEST_MODE='${TEST_MODE:-}'"
  echo "Allowed values: ${ALLOWED_TEST_MODES// /, }"
  # k0rdent/catalog uses aws|azure|gcp|adopted, so a TEST_MODE exported for it
  # leaks into this project and lands here.
  echo "Hint: 'unset TEST_MODE' if it is left over from another project."
  exit 1
fi
