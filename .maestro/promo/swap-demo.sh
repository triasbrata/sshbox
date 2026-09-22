#!/bin/sh
# Recreates jeansh-demo from jeansh-demo:claude (see Dockerfile beside this),
# keeping its /config volume — home, sshd_config and the host keys the
# emulator has pinned — its run-time env, its hostname and port 2222.
# jeansh-mongo and jeansh-redis live in jeansh-demo's network namespace, which
# Docker records by container id, so they are recreated to join the new one on
# the same volumes. The old three are kept as *-old for rollback.
# Nothing secret is printed: the env goes through a 0600 temp file.
set -eu
d() { sudo docker "$@"; }
vol() { d inspect "$1" --format "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}"; }

env=$(mktemp)
trap 'rm -f "$env"' EXIT
# Only what was set at `docker run`; the rest comes from the same base image.
d inspect jeansh-demo --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(PUID|PGID|TZ|USER_NAME|USER_PASSWORD|PASSWORD_ACCESS|SUDO_ACCESS)=' > "$env"
config=$(vol jeansh-demo /config)
db=$(vol jeansh-mongo /data/db)
configdb=$(vol jeansh-mongo /data/configdb)
rdata=$(vol jeansh-redis /data)
hn=$(d inspect jeansh-demo --format '{{.Config.Hostname}}')

d stop jeansh-redis jeansh-mongo jeansh-demo
for c in jeansh-demo jeansh-mongo jeansh-redis; do d rename "$c" "$c-old"; done

d run -d --name jeansh-demo --hostname "$hn" -p 2222:2222 --env-file "$env" \
  -v "$config":/config jeansh-demo:claude
d run -d --name jeansh-mongo --network container:jeansh-demo \
  -v "$db":/data/db -v "$configdb":/data/configdb mongo:7 --ipv6 --bind_ip_all
d run -d --name jeansh-redis --network container:jeansh-demo -v "$rdata":/data redis:7
