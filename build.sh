#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/build-versions.env"

CLANG_DIR="${CLANG_DIR:-/root/clang}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-/root/AnyKernel3}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
JOBS="${JOBS:-$(nproc)}"
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-t.me}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-AnymoreProject}"
KERNEL_RELEASE="4.14.357+17-perf"

export ARCH=arm64
export KBUILD_BUILD_USER KBUILD_BUILD_HOST
export PATH="$CLANG_DIR/bin:$PATH"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_neutron_tool() {
  local tool="$1"
  local expected_identity="$2"
  local identity
  command -v "$tool" >/dev/null 2>&1 || die "required tool is not available: $tool"
  identity="$("$tool" --version 2>&1)" || die "cannot query $tool identity"
  grep -Fq -- "$expected_identity" <<<"$identity" ||
    die "$tool does not report expected identity: $expected_identity"
  grep -Fq -- "$NEUTRON_LLVM_COMMIT" <<<"$identity" ||
    die "$tool does not identify pinned Neutron LLVM $NEUTRON_LLVM_COMMIT"
}

[[ -x "$CLANG_DIR/bin/clang" ]] || die "clang is missing from CLANG_DIR: $CLANG_DIR"
[[ -x "$CLANG_DIR/bin/ld.lld" ]] || die "ld.lld is missing from CLANG_DIR: $CLANG_DIR"
require_neutron_tool clang 'Neutron clang version 24.0.0git'
require_neutron_tool ld.lld 'Neutron LLD 24.0.0 ('
clang_identity="$(clang --version)"
lld_identity="$(ld.lld --version)"

git -C "$ROOT_DIR" submodule update --init --depth 1 KernelSU-Next
bash "$ROOT_DIR/scripts/prepare-ksu-susfs.sh"

mkdir -p "$OUT_DIR" "$ARTIFACTS_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

make -C "$ROOT_DIR" -j"$JOBS" O="$OUT_DIR" ARCH=arm64 vayu_defconfig
[[ -s "$OUT_DIR/.config" ]] || die "vayu_defconfig did not create .config"

make -C "$ROOT_DIR" -j"$JOBS" \
  O="$OUT_DIR" \
  ARCH=arm64 \
  SUBARCH=arm64 \
  DTC_EXT=dtc \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
  LD=ld.lld \
  AR=llvm-ar \
  NM=llvm-nm \
  STRIP=llvm-strip \
  OBJCOPY=llvm-objcopy \
  OBJDUMP=llvm-objdump \
  READELF=llvm-readelf \
  HOSTCC=clang \
  HOSTCXX=clang++ \
  HOSTAR=llvm-ar \
  HOSTLD=ld.lld \
  LLVM=1 \
  LLVM_IAS=1 \
  CC='ccache clang'

for output in Image dtb.img dtbo.img; do
  [[ -s "$OUT_DIR/arch/arm64/boot/$output" ]] ||
    die "required build output is missing: $output"
done

cp "$OUT_DIR/.config" "$ARTIFACTS_DIR/kernel.config"
kernel_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
{
  printf 'Linux version %s\n' "$KERNEL_RELEASE"
  printf '%s\n' "$clang_identity"
  printf '%s\n' "$lld_identity"
  printf 'Kernel source commit %s\n' "$kernel_sha"
  printf 'KernelSU-Next %s %s\n' "$KERNELSU_NEXT_VERSION" "$KERNELSU_NEXT_COMMIT"
  printf 'SuSFS %s %s\n' "$SUSFS_VERSION" "$SUSFS_COMMIT"
  printf 'AnyKernel3 %s\n' "$ANYKERNEL3_COMMIT"
  printf 'Neutron catalogue %s\n' "$NEUTRON_CATALOGUE_COMMIT"
  printf 'Neutron archive sha256 %s\n' "$NEUTRON_ARCHIVE_SHA256"
  printf 'KBUILD_BUILD_USER=%s\n' "$KBUILD_BUILD_USER"
  printf 'KBUILD_BUILD_HOST=%s\n' "$KBUILD_BUILD_HOST"
} > "$ARTIFACTS_DIR/build-info.txt"

OUT_DIR="$OUT_DIR" ANYKERNEL_DIR="$ANYKERNEL_DIR" ARTIFACTS_DIR="$ARTIFACTS_DIR" \
  bash "$ROOT_DIR/scripts/package-anykernel.sh"
