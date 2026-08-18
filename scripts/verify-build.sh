#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

artifacts_dir="${1:-${ARTIFACTS_DIR:-artifacts}}"
: "${EXPECTED_LLVM_COMMIT:?EXPECTED_LLVM_COMMIT must be set}"
: "${EXPECTED_KERNEL_RELEASE:?EXPECTED_KERNEL_RELEASE must be set}"

[[ -d "$artifacts_dir" ]] || die "artifact directory does not exist: $artifacts_dir"

for required_file in build-info.txt kernel.config Image dtb.img dtbo.img; do
  [[ -s "$artifacts_dir/$required_file" ]] || die "required non-empty artifact is missing: $required_file"
done

mapfile -t zip_files < <(find "$artifacts_dir" -maxdepth 1 -type f -name '*.zip' -print)
(( ${#zip_files[@]} == 1 )) || die "expected exactly one ZIP artifact, found ${#zip_files[@]}"

build_info="$artifacts_dir/build-info.txt"
kernel_config="$artifacts_dir/kernel.config"
zip_file="${zip_files[0]}"

grep -Fqx -- "Linux version $EXPECTED_KERNEL_RELEASE" "$build_info" >/dev/null ||
  die "kernel release does not match"
grep -Fqx -- 'Neutron clang version 24.0.0git' "$build_info" >/dev/null ||
  die "compiler identity does not match"
grep -Fqx -- "$EXPECTED_LLVM_COMMIT" "$build_info" >/dev/null ||
  die "LLVM commit does not match"
grep -Fqx -- 'CONFIG_KSU=y' "$kernel_config" >/dev/null ||
  die "CONFIG_KSU is not enabled"
grep -Fqx -- 'CONFIG_KSU_SUSFS=y' "$kernel_config" >/dev/null ||
  die "CONFIG_KSU_SUSFS is not enabled"

for archive_member in Image dtb.img dtbo.img; do
  if ! unzip -Z1 "$zip_file" 2>/dev/null | grep -Fqx -- "$archive_member"; then
    die "ZIP artifact is missing $archive_member"
  fi
done

printf 'Build artifacts verified: %s\n' "$zip_file"
