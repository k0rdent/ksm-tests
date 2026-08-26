#!/bin/bash
# Helpers for reading $SERVICES_FILE. Expects common.sh to be sourced first.

# service_count -- how many services are declared.
service_count() {
    yq -r '.services | length' "$SERVICES_FILE"
}

# SERVICE_SEP must not be whitespace: `read` with a whitespace IFS collapses
# runs of it, which silently drops empty fields and shifts every later value
# left. Optional fields like dependsOn are routinely empty.
# shellcheck disable=SC2034 # used by the scripts that source this
SERVICE_SEP='|'

# services_rows -- one line per service, SERVICE_SEP separated:
#   name|chart|version|repo|namespace|dependsOn|waitForPods
services_rows() {
    yq -r '.services[] | [.name, .chart, .version, .repo, .namespace,
                          (.dependsOn // ""), (.waitForPods // "")] | join("|")' "$SERVICES_FILE"
}

# service_namespaces -- each target namespace once, in declaration order.
service_namespaces() {
    yq -r '.services[].namespace' "$SERVICES_FILE" | awk '!seen[$0]++'
}

# service_values NAME -- the values block for one service, empty if it has none.
service_values() {
    NAME="$1" yq -r '.services[] | select(.name == strenv(NAME)) | .values // ""' "$SERVICES_FILE"
}

# service_field NAME FIELD
service_field() {
    NAME="$1" FIELD="$2" yq -r \
        '.services[] | select(.name == strenv(NAME)) | .[strenv(FIELD)] // ""' "$SERVICES_FILE"
}

# template_name_for CHART VERSION -- the ServiceTemplate name, matching the
# <chart>-<version with dashes> convention KCM uses everywhere else.
template_name_for() {
    echo "$1-$(fqdn_version "$2")"
}

# repo_type REPO -- flux needs spec.type=oci for OCI registries.
repo_type() {
    [[ "$1" == oci://* ]] && echo oci || echo default
}
