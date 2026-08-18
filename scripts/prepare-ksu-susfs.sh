#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0001-susfs-2.2.0.patch"
COMPAT_PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0002-linux-4.14-file-wrapper.patch"
SECCOMP_PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0003-linux-4.14-seccomp-cache.patch"
MOUNT_PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0004-linux-4.14-mount-api.patch"
FSNOTIFY_PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0005-linux-4.14-fsnotify.patch"
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
else
  git -C "$KSU_DIR" apply --check "$PATCH_FILE"
  git -C "$KSU_DIR" apply "$PATCH_FILE"
  printf 'Applied SuSFS %s integration to KernelSU-Next %s\n' \
    "$SUSFS_VERSION" "$KERNELSU_NEXT_VERSION"
fi

if git -C "$KSU_DIR" apply --reverse --check "$COMPAT_PATCH_FILE" >/dev/null 2>&1; then
  printf 'KernelSU-Next Linux 4.14 file wrapper patch is already applied\n'
else
  git -C "$KSU_DIR" apply --check "$COMPAT_PATCH_FILE"
  git -C "$KSU_DIR" apply "$COMPAT_PATCH_FILE"
  printf 'Applied KernelSU-Next Linux 4.14 file wrapper compatibility\n'
fi

if git -C "$KSU_DIR" apply --reverse --check "$SECCOMP_PATCH_FILE" >/dev/null 2>&1; then
  printf 'KernelSU-Next Linux 4.14 seccomp cache patch is already applied\n'
else
  git -C "$KSU_DIR" apply --check "$SECCOMP_PATCH_FILE"
  git -C "$KSU_DIR" apply "$SECCOMP_PATCH_FILE"
  printf 'Applied fail-closed KernelSU-Next Linux 4.14 seccomp compatibility\n'
fi

if git -C "$KSU_DIR" apply --reverse --check "$MOUNT_PATCH_FILE" >/dev/null 2>&1; then
  printf 'KernelSU-Next Linux 4.14 mount patch is already applied\n'
else
  git -C "$KSU_DIR" apply --check "$MOUNT_PATCH_FILE"
  git -C "$KSU_DIR" apply "$MOUNT_PATCH_FILE"
  printf 'Applied KernelSU-Next Linux 4.14 mount compatibility\n'
fi

if git -C "$KSU_DIR" apply --reverse --check "$FSNOTIFY_PATCH_FILE" >/dev/null 2>&1; then
  printf 'KernelSU-Next Linux 4.14 fsnotify patch is already applied\n'
else
  git -C "$KSU_DIR" apply --check "$FSNOTIFY_PATCH_FILE"
  git -C "$KSU_DIR" apply "$FSNOTIFY_PATCH_FILE"
  printf 'Applied KernelSU-Next Linux 4.14 fsnotify compatibility\n'
fi

expected_uid_api_uses=24
uid_api_uses="$({ grep -RhoF 'current_uid().val' "$KSU_DIR/kernel" || true; } | wc -l | tr -d ' ')"
if [[ "$uid_api_uses" != 0 && "$uid_api_uses" != "$expected_uid_api_uses" ]]; then
  printf 'Unexpected KernelSU current_uid().val use count: %s\n' "$uid_api_uses" >&2
  exit 1
fi
if [[ "$uid_api_uses" == "$expected_uid_api_uses" ]]; then
  grep -RlF 'current_uid().val' "$KSU_DIR/kernel" |
    xargs sed -i 's/current_uid()\.val/__kuid_val(current_uid())/g'
fi

sucompat_file="$KSU_DIR/kernel/feature/sucompat.c"
if grep -Fq '#include <linux/pgtable.h>' "$sucompat_file"; then
  sed -i 's|<linux/pgtable.h>|<asm/pgtable.h>|' "$sucompat_file"
fi
grep -Fq '#include <asm/pgtable.h>' "$sucompat_file" || {
  printf 'KernelSU sucompat pgtable compatibility include is missing\n' >&2
  exit 1
}

icache_file="$KSU_DIR/kernel/hook/arm64/patch_memory.c"
if grep -Fq '#define ksu_flush_icache(start, end) __flush_icache_range' "$icache_file"; then
  sed -i 's/__flush_icache_range/flush_icache_range/' "$icache_file"
fi
grep -Fq '#define ksu_flush_icache(start, end) flush_icache_range' "$icache_file" || {
  printf 'KernelSU arm64 instruction-cache compatibility mapping is missing\n' >&2
  exit 1
}
