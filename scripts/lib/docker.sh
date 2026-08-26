#!/bin/bash
# Docker helpers. Expects scripts/lib/common.sh to be sourced first.

# container_exists NAME -- true for running *or* stopped containers.
container_exists() {
    [[ -n "$(docker ps -a --filter "name=^$1\$" --format '{{.Names}}')" ]]
}

# container_running NAME
container_running() {
    [[ -n "$(docker ps --filter "name=^$1\$" --format '{{.Names}}')" ]]
}

# port_in_use PORT -- probe 127.0.0.1 without needing ss/lsof/root.
port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
    exec 3<&- 3>&-
    return 0
}

# free_port START -- first free port at or after START.
free_port() {
    local port="$1" limit=$(( $1 + 100 ))
    while (( port < limit )); do
        port_in_use "$port" || { echo "$port"; return 0; }
        port=$(( port + 1 ))
    done
    return 1
}

# published_port CONTAINER PORT -- host port a container port maps to.
published_port() {
    docker port "$1" "$2" 2>/dev/null | head -1 | awk -F: '{print $NF}'
}

# ensure_network NAME -- create the docker network unless it already exists.
ensure_network() {
    local name="$1"
    if docker network inspect "$name" >/dev/null 2>&1; then
        log "Docker network '$name' already exists"
    else
        log "Creating docker network '$name'"
        docker network create "$name" >/dev/null
    fi
}

# connect_network NETWORK CONTAINER -- idempotent `docker network connect`.
connect_network() {
    local network="$1" container="$2"
    if docker network inspect "$network" --format '{{range .Containers}}{{.Name}} {{end}}' \
        | tr ' ' '\n' | grep -qx "$container"; then
        log "Container '$container' is already on network '$network'"
    else
        docker network connect "$network" "$container"
        log "Connected '$container' to network '$network'"
    fi
}

# import_image_into_k0s IMAGE CONTAINER
#
# The k0s-in-docker equivalent of `kind load docker-image`: stream the image
# straight into the node's containerd under the k8s.io namespace.
import_image_into_k0s() {
    local image="$1" container="$2"
    log "Importing $image into $container"
    docker save "$image" | docker exec -i "$container" k0s ctr -n k8s.io images import - >/dev/null
}
