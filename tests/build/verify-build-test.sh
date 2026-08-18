#!/usr/bin/env bash
set -euo pipefail

root_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$root_dir/scripts/verify-build.sh"
expected_llvm_commit="17efc66a340e35ae03a18e34e7f267832fff7940"
expected_kernel_release="4.14.357+17-perf"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

create_zip() {
  local source_dir="$1"
  local destination="$2"
  local python_cmd=''
  shift 2
  if command -v zip >/dev/null 2>&1; then
    (
      cd "$source_dir"
      zip -q "$destination" "$@"
    )
  elif command -v python >/dev/null 2>&1 || command -v py >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1; then
      python_cmd='python'
    else
      python_cmd='py'
    fi
    "$python_cmd" - "$destination" "$source_dir" "$@" <<'PY'
import pathlib
import sys
import zipfile

destination = pathlib.Path(sys.argv[1])
source_dir = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(destination, 'w') as archive:
    for member in sys.argv[3:]:
        archive.write(source_dir / member, member)
PY
  else
    fail 'zip or python is required to construct test fixtures'
  fi
}

make_fixture() {
  local artifacts_dir="$1"
  mkdir -p "$artifacts_dir/zip-content"
  printf 'Linux version 4.14.357+17-perf\nNeutron clang version 24.0.0git\n17efc66a340e35ae03a18e34e7f267832fff7940\n' > "$artifacts_dir/build-info.txt"
  printf 'CONFIG_KSU=y\nCONFIG_KSU_SUSFS=y\n' > "$artifacts_dir/kernel.config"
  printf 'kernel image\n' > "$artifacts_dir/Image"
  printf 'device tree\n' > "$artifacts_dir/dtb.img"
  printf 'device tree overlay\n' > "$artifacts_dir/dtbo.img"
  cp "$artifacts_dir/Image" "$artifacts_dir/dtb.img" "$artifacts_dir/dtbo.img" "$artifacts_dir/zip-content/"
  create_zip "$artifacts_dir/zip-content" "$artifacts_dir/anykernel.zip" Image dtb.img dtbo.img
  rm -rf "$artifacts_dir/zip-content"
}

run_verifier() {
  ARTIFACTS_DIR="$1" EXPECTED_LLVM_COMMIT="$expected_llvm_commit" EXPECTED_KERNEL_RELEASE="$expected_kernel_release" bash "$verifier"
}

expect_rejected() {
  local description="$1"
  local artifacts_dir="$2"
  if run_verifier "$artifacts_dir" >/dev/null 2>&1; then
    fail "accepted fixture with $description"
  fi
}

replace_zip_without() {
  local artifacts_dir="$1"
  local excluded_member="$2"
  local members=()
  rm -f "$artifacts_dir/anykernel.zip"
  mkdir -p "$artifacts_dir/zip-content"
  for member in Image dtb.img dtbo.img; do
    if [[ "$member" != "$excluded_member" ]]; then
      cp "$artifacts_dir/$member" "$artifacts_dir/zip-content/$member"
      members+=("$member")
    fi
  done
  create_zip "$artifacts_dir/zip-content" "$artifacts_dir/anykernel.zip" "${members[@]}"
  rm -rf "$artifacts_dir/zip-content"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

valid_dir="$tmp_dir/valid"
make_fixture "$valid_dir"
run_verifier "$valid_dir" || fail 'rejected valid build fixture'
ARTIFACTS_DIR="$tmp_dir/not-used" EXPECTED_LLVM_COMMIT="$expected_llvm_commit" EXPECTED_KERNEL_RELEASE="$expected_kernel_release" bash "$verifier" "$valid_dir" || fail 'did not accept an explicit artifact directory'

missing_dir="$tmp_dir/missing"
make_fixture "$missing_dir"
rm "$missing_dir/build-info.txt"
expect_rejected 'a missing required file' "$missing_dir"

duplicate_dir="$tmp_dir/duplicate"
make_fixture "$duplicate_dir"
cp "$duplicate_dir/anykernel.zip" "$duplicate_dir/second.zip"
expect_rejected 'duplicate ZIPs' "$duplicate_dir"

compiler_dir="$tmp_dir/compiler"
make_fixture "$compiler_dir"
printf 'Linux version 4.14.357+17-perf\nClang version 24.0.0git\n17efc66a340e35ae03a18e34e7f267832fff7940\n' > "$compiler_dir/build-info.txt"
expect_rejected 'wrong compiler identity' "$compiler_dir"

ksu_dir="$tmp_dir/ksu"
make_fixture "$ksu_dir"
printf 'CONFIG_KSU=y\n' > "$ksu_dir/kernel.config"
expect_rejected 'absent KSU flags' "$ksu_dir"

for member in Image dtb.img dtbo.img; do
  zip_dir="$tmp_dir/zip-$member"
  make_fixture "$zip_dir"
  replace_zip_without "$zip_dir" "$member"
  expect_rejected "a ZIP lacking $member" "$zip_dir"
done

printf 'PASS: build artifact verifier accepts one valid fixture and rejects all required invalid fixtures\n'

