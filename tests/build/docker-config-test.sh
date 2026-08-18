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

require_literal() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
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
require_file scripts/anykernel-overlay/anykernel.sh

# shellcheck disable=SC1091
source scripts/build-versions.env

require_match Dockerfile '^FROM [^[:space:]]*ubuntu(:[^@[:space:]]+)?@sha256:[a-f0-9]{64}($|[[:space:]])'
require_literal Dockerfile 'apt-get install -y --no-install-recommends'
require_literal Dockerfile 'device-tree-compiler'
require_literal Dockerfile 'NEUTRON_ARCHIVE_URL'
require_literal Dockerfile 'NEUTRON_CATALOGUE_MANIFEST_URL'
require_literal Dockerfile 'NEUTRON_ARCHIVE_SHA256'
require_literal Dockerfile 'sha256sum -c'
if grep -Fq '\\n' Dockerfile; then
  fail 'Dockerfile printf formats must use shell newline escapes, not literal backslashes'
fi
require_literal Dockerfile 'clang --version'
require_literal Dockerfile 'ld.lld --version'
require_literal Dockerfile "grep -F 'Neutron LLD 24.0.0 ('"
require_literal Dockerfile '24.0.0git'
require_literal Dockerfile 'NEUTRON_LLVM_COMMIT'
require_match Dockerfile '^USER [^[:space:]]+'

# AnyKernel must derive from an immutable vayu/bhima source and remain clean after
# the deterministic metadata overlay is installed.
[[ "$ANYKERNEL3_REPOSITORY" == 'https://github.com/Kurozuka97/AnyKernel3_vayu.git' ]] ||
  fail 'unexpected AnyKernel3 repository pin'
[[ "$ANYKERNEL3_REF" == 'master' ]] || fail 'unexpected AnyKernel3 ref pin'
[[ "$ANYKERNEL3_COMMIT" == '91e063d31dbe4b485ce00c26b1bf856696cba3c5' ]] ||
  fail 'unexpected AnyKernel3 commit pin'
require_literal Dockerfile 'ANYKERNEL_DIR=/opt/AnyKernel3'
require_literal Dockerfile 'git -C "$ANYKERNEL_DIR" remote add origin "$ANYKERNEL3_REPOSITORY"'
require_literal Dockerfile 'git -C "$ANYKERNEL_DIR" fetch --depth 1 origin "$ANYKERNEL3_REF"'
require_literal Dockerfile 'test "$(git -C "$ANYKERNEL_DIR" rev-parse FETCH_HEAD)" = "$ANYKERNEL3_COMMIT"'
require_literal Dockerfile 'git -C "$ANYKERNEL_DIR" reset --hard "$ANYKERNEL3_COMMIT"'
require_literal Dockerfile 'git -C "$ANYKERNEL_DIR" clean -ffdqx'
require_literal Dockerfile 'git -C "$ANYKERNEL_DIR" update-index --assume-unchanged anykernel.sh'
require_literal Dockerfile 'chown -R builder:builder /workspace "$CCACHE_DIR" "$ANYKERNEL_DIR"'
require_literal Dockerfile 'device.name1=vayu'
require_literal Dockerfile 'device.name2=bhima'
require_literal Dockerfile 'supported.versions=11 - 17'
require_literal Dockerfile 'KyriePatch'
require_literal scripts/anykernel-overlay/anykernel.sh 'device.name1=vayu'
require_literal scripts/anykernel-overlay/anykernel.sh 'device.name2=bhima'
require_literal scripts/anykernel-overlay/anykernel.sh 'supported.versions=11 - 17'
require_literal scripts/anykernel-overlay/anykernel.sh 'kernel.string=KyriePatch'

require_match docker-compose.yml '^services:'
require_literal docker-compose.yml 'HOST_UID'
require_literal docker-compose.yml 'HOST_GID'
require_literal docker-compose.yml './out:/workspace/out'
require_literal docker-compose.yml './artifacts:/workspace/artifacts'
require_literal docker-compose.yml 'ccache:/ccache'
require_match docker-compose.yml '^volumes:'

require_match scripts/docker-build.sh '^set -Eeuo pipefail$'
require_literal scripts/docker-build.sh 'docker compose version'
require_literal scripts/docker-build.sh 'git submodule update --init --recursive'
require_literal scripts/docker-build.sh 'mkdir -p "$ROOT_DIR/out" "$ROOT_DIR/artifacts"'
require_literal scripts/docker-build.sh 'docker compose build kernel-builder'
require_literal scripts/docker-build.sh 'docker compose run --rm kernel-builder ./build.sh'

if grep -Eq '^FROM [^@[:space:]]+(:latest|:[^@[:space:]]+)?[[:space:]]*$' Dockerfile; then
  fail 'Dockerfile contains a floating image tag'
fi

printf 'PASS: Docker build configuration contract\n'
