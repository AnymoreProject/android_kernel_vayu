#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_match() {
  local file="$1"
  local pattern="$2"
  grep -Eq -- "$pattern" "$file" || fail "$file does not match: $pattern"
}

require_file Dockerfile
require_file .dockerignore
require_file docker-compose.yml
require_file scripts/docker-build.sh
require_file scripts/build-versions.env

require_match Dockerfile '^FROM [^[:space:]]*ubuntu(:[^@[:space:]]+)?@sha256:[a-f0-9]{64}($|[[:space:]])'
require_match Dockerfile 'apt-get install -y --no-install-recommends'
require_match Dockerfile 'NEUTRON_ARCHIVE_SHA256'
require_match Dockerfile 'sha256sum -c'
require_match Dockerfile 'neutron-clang-30072026\.tar\.zst'
require_match Dockerfile 'clang --version'
require_match Dockerfile 'ld\.lld --version'
require_match Dockerfile '24\.0\.0git'
require_match Dockerfile 'NEUTRON_LLVM_COMMIT'
require_match Dockerfile '^USER [^[:space:]]+'

require_match docker-compose.yml '^services:'
require_match docker-compose.yml 'HOST_UID'
require_match docker-compose.yml 'HOST_GID'
require_match docker-compose.yml 'out:/workspace/out'
require_match docker-compose.yml 'artifacts:/workspace/artifacts'
require_match docker-compose.yml 'ccache:/ccache'
require_match docker-compose.yml '^volumes:'

require_match scripts/docker-build.sh '^set -Eeuo pipefail$'
require_match scripts/docker-build.sh 'docker compose version'
require_match scripts/docker-build.sh 'git submodule update --init --recursive'
require_match scripts/docker-build.sh 'mkdir -p .*out .*artifacts'
require_match scripts/docker-build.sh 'docker compose build kernel-builder'
require_match scripts/docker-build.sh 'docker compose run --rm kernel-builder ./build\.sh'

if grep -Eq '^FROM [^@[:space:]]+(:latest|:[^@[:space:]]+)?[[:space:]]*$' Dockerfile; then
  fail 'Dockerfile contains a floating image tag'
fi

printf 'PASS: Docker build configuration contract\n'
