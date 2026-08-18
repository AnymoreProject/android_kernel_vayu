#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0001-susfs-2.2.0.patch"
KSU_DIR="$ROOT_DIR/KernelSU-Next"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/build-versions.env"

[[ -d "$KSU_DIR" ]] || {
  printf 'KernelSU-Next submodule is not initialized\n' >&2
  exit 1
}

actual_commit="$(git -C "$KSU_DIR" rev-parse HEAD)"
[[ "$actual_commit" == "$KERNELSU_NEXT_COMMIT" ]] || {
  printf 'KernelSU-Next pin mismatch: expected %s, got %s\n'     "$KERNELSU_NEXT_COMMIT" "$actual_commit" >&2
  exit 1
}

if git -C "$KSU_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  printf 'KernelSU-Next SuSFS patch is already applied\n'
  exit 0
fi

git -C "$KSU_DIR" apply --check "$PATCH_FILE"
git -C "$KSU_DIR" apply "$PATCH_FILE"
printf 'Applied SuSFS %s integration to KernelSU-Next %s\n'   "$SUSFS_VERSION" "$KERNELSU_NEXT_VERSION"
