#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v docker >/dev/null 2>&1 || {
  printf 'ERROR: Docker is required.\n' >&2
  exit 1
}
docker compose version >/dev/null

git submodule sync --recursive
git submodule update --init --recursive

mkdir -p "$ROOT_DIR/out" "$ROOT_DIR/artifacts"
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

docker compose build kernel-builder
docker compose run --rm kernel-builder ./build.sh
