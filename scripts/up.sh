#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "up.sh: $*" >&2; exit 1; }

[ -f .env ] || die "edge/.env is missing — copy .env.example and fill it in"

for network in $(docker compose config | awk '/^[^ ]/ { section = ($0 == "networks:") } section && $1 == "name:" { print $2 }'); do
    docker network inspect "$network" > /dev/null 2>&1 || docker network create "$network"
done

docker compose pull
docker compose up -d --remove-orphans
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
docker compose ps
