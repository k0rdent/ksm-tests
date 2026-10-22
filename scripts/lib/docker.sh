#!/usr/bin/env bash
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

# container_ip NAME NETWORK -- its address on that docker network.
# shellcheck disable=SC2317 # called from deploy_adopted_cluster.sh, not here
container_ip() {
    docker inspect "$1" -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" 2>/dev/null
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

# start_k0s_container NAME PORT -- one k0s node in Docker on $DOCKER_NETWORK,
# reachable from the host on 127.0.0.1:$K0S_API_PORT, which this sets. Not a
# return value: log() writes to stdout, so a captured echo would carry it.
# Idempotent -- a running container is reused at whatever port it already has.
start_k0s_container() {
    local name="$1"
    K0S_API_PORT="$2"

    if container_running "$name"; then
        K0S_API_PORT="$(published_port "$name" 6443)"
        [[ -n "$K0S_API_PORT" ]] || die "Container '$name' publishes no port for 6443"
        log "Container '$name' already running, API on 127.0.0.1:$K0S_API_PORT"
    else
        if container_exists "$name"; then
            log "Removing stale container '$name'"
            docker rm -vf "$name" >/dev/null
        fi

        if port_in_use "$K0S_API_PORT"; then
            local new_port
            new_port="$(free_port "$K0S_API_PORT")" \
                || die "No free port near $K0S_API_PORT for the API server"
            warn "Port $K0S_API_PORT is taken, using $new_port instead"
            K0S_API_PORT="$new_port"
        fi

        log "Starting $K0S_IMAGE as '$name'"
        docker run -d \
            --name "$name" \
            --hostname "$name" \
            --network "$DOCKER_NETWORK" \
            --privileged \
            -v /var/lib/k0s \
            -v /var/log/pods \
            -v /var/run/docker.sock:/var/run/docker.sock \
            --tmpfs /run \
            -p "127.0.0.1:$K0S_API_PORT:6443" \
            "$K0S_IMAGE" >/dev/null

        log "Waiting for the k0s admin kubeconfig..."
        until docker exec "$name" k0s kubeconfig admin >/dev/null 2>&1; do
            sleep 2
        done
    fi

    # hostPath mounts with propagation (used by the CAPD controller and by the
    # CSI bits of the child clusters) need a recursively shared root. kind sets
    # this up for its nodes; the plain k0s image does not.
    docker exec "$name" mount --make-rshared /
}

# write_k0s_kubeconfig CONTAINER SERVER FILE -- the admin kubeconfig, pointed at
# SERVER. k0s writes the container's own internal address, which is reachable
# from neither the host nor another container.
write_k0s_kubeconfig() {
    local container="$1" server="$2" file="$3"
    docker exec "$container" k0s kubeconfig admin > "$file"
    sed -i.bak "s#server:.*#server: $server#" "$file"
    rm -f "$file.bak"
    chmod 0600 "$file"
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

# container_ip NAME NETWORK -- address on that network.
container_ip() {
    docker inspect "$1" \
        --format "{{ (index .NetworkSettings.Networks \"$2\").IPAddress }}" 2>/dev/null
}
