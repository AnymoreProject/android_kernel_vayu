#!/usr/bin/env bash
set -euo pipefail

root_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root_dir/.github/workflows/docker-build.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local literal="$1"
  grep -F -- "$literal" "$workflow" >/dev/null || fail "workflow is missing: $literal"
}

[[ -f "$workflow" ]] || fail 'Docker build workflow does not exist'

require_literal 'workflow_dispatch:'
require_literal 'pull_request:'
require_literal 'branches: [16]'
require_literal 'codex/docker-ksun-build'
require_literal 'permissions:'
require_literal 'contents: read'
require_literal 'submodules: recursive'
require_literal 'docker/setup-buildx-action@'
require_literal 'cache-from=type=gha'
require_literal 'cache-to=type=gha,mode=max'
require_literal 'ccache'
require_literal 'df -Pk .'
require_literal 'mkdir -p out artifacts'
require_literal 'HOST_UID=$(id -u)'
require_literal 'HOST_GID=$(id -g)'
require_literal 'GITHUB_ENV'
require_literal 'docker compose run --rm kernel-builder ./build.sh'
require_literal './scripts/verify-build.sh artifacts'
require_literal 'name: anymore-vayu-kernel'
require_literal 'if-no-files-found: error'
require_literal 'retention-days: 14'
for artifact in '*.zip' Image dtb.img dtbo.img kernel.config build-info.txt; do
  require_literal "artifacts/$artifact"
done

if grep -Eq 'uses: [^#[:space:]]+@v[0-9]+([[:space:]]|$)' "$workflow"; then
  fail 'official actions must be pinned to immutable commit SHAs'
fi

printf 'PASS: GitHub Actions workflow satisfies the Docker build and artifact contract\n'
