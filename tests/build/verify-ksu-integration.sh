#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VERSIONS_FILE="$ROOT_DIR/scripts/build-versions.env"
DEFCONFIG="$ROOT_DIR/arch/arm64/configs/vayu_defconfig"
PATCH_FILE="$ROOT_DIR/patches/KernelSU-Next/0001-susfs-2.2.0.patch"
TEMP_DIR=""
PATCHED_ACTUAL=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "$PATCHED_ACTUAL" == 1 ]]; then
    git -C "$ROOT_DIR/KernelSU-Next" apply --reverse "$PATCH_FILE" >/dev/null 2>&1 || true
  fi
  [[ -z "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

require_file() {
  [[ -f "$ROOT_DIR/$1" ]] || fail "missing $1"
}

require_line() {
  local file="$1"
  local line="$2"
  grep -Fqx -- "$line" "$ROOT_DIR/$file" ||
    fail "$file is missing exact line: $line"
}

require_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$ROOT_DIR/$file" ||
    fail "$file is missing: $needle"
}

require_hex() {
  local name="$1"
  local length="$2"
  local value="${!name:-}"
  [[ "$value" =~ ^[0-9a-f]{$length}$ ]] ||
    fail "$name must be an immutable lowercase $length-character hexadecimal pin"
}

require_equals() {
  local name="$1"
  local expected="$2"
  [[ "${!name:-}" == "$expected" ]] ||
    fail "$name does not match the reviewed upstream pin"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

require_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(file_sha256 "$ROOT_DIR/$file")"
  [[ "$actual" == "$expected" ]] ||
    fail "$file is not the byte-exact reviewed SuSFS v2.2.0 source"
}

require_file "scripts/build-versions.env"
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

require_hex KERNELSU_NEXT_COMMIT 40
require_hex SUSFS_COMMIT 40
require_hex ANYKERNEL3_COMMIT 40
require_hex NEUTRON_LLVM_COMMIT 40
require_hex NEUTRON_CATALOGUE_COMMIT 40
require_hex NEUTRON_ARCHIVE_SHA256 64

require_equals KERNELSU_NEXT_COMMIT 3b18216f71df189ab3d1b1ce0bdb21be1268e771
require_equals SUSFS_COMMIT ab4c23cfc7cb26821abb7a9d2071206713c070fe
require_equals ANYKERNEL3_COMMIT e4b1bb25ca2aabcfd57f694a5998d87130701b71
require_equals NEUTRON_LLVM_COMMIT 17efc66a340e35ae03a18e34e7f267832fff7940
require_equals NEUTRON_CATALOGUE_COMMIT 08446d3f53116791558002ae19c61d41e4fb797a
require_equals NEUTRON_ARCHIVE_SHA256 aa1567215d2be42d0d054ae72627e6d18ef6ac80205847f1e7ce0db5736476f3
[[ "${KERNELSU_NEXT_VERSION:-}" == "v3.3.0" ]] || fail "KernelSU-Next version must be v3.3.0"
[[ "${SUSFS_VERSION:-}" == "v2.2.0" ]] || fail "SuSFS version must be v2.2.0"

require_file "patches/KernelSU-Next/0001-susfs-2.2.0.patch"
TEMP_DIR="$(mktemp -d)"
KSU_TREE="$TEMP_DIR/KernelSU-Next"
mkdir -p "$KSU_TREE"
if [[ -n "${KSU_SOURCE_DIR:-}" ]]; then
  [[ -d "$KSU_SOURCE_DIR/kernel" ]] || fail "KSU_SOURCE_DIR is not a KernelSU-Next source tree"
  cp -a "$KSU_SOURCE_DIR/." "$KSU_TREE/"
else
  git -C "$ROOT_DIR" submodule update --init --depth 1 KernelSU-Next
  actual_commit="$(git -C "$ROOT_DIR/KernelSU-Next" rev-parse HEAD)"
  [[ "$actual_commit" == "$KERNELSU_NEXT_COMMIT" ]] ||
    fail "KernelSU-Next submodule is not at the immutable pin"
  [[ -z "$(git -C "$ROOT_DIR/KernelSU-Next" status --porcelain --untracked-files=no)" ]] ||
    fail "KernelSU-Next submodule must be clean before verification"
  cp -a "$ROOT_DIR/KernelSU-Next/." "$KSU_TREE/"
fi
rm -rf "$KSU_TREE/.git"

git -C "$KSU_TREE" apply --check "$PATCH_FILE" ||
  fail "SuSFS patch does not apply to the pinned KernelSU-Next source"
git -C "$KSU_TREE" apply "$PATCH_FILE"
git -C "$KSU_TREE" apply --reverse --check "$PATCH_FILE" ||
  fail "SuSFS patch was not applied cleanly"
grep -Fq "config KSU_SUSFS" "$KSU_TREE/kernel/Kconfig" ||
  fail "patched KernelSU Kconfig is missing KSU_SUSFS"
for hook in \
  "susfs_init();" \
  "bool susfs_is_current_ksu_domain(void)" \
  "susfs_start_sdcard_monitor_fn();" \
  "case CMD_SUSFS_SET_UNAME:" \
  "case CMD_SUSFS_ENABLE_LOG:" \
  "case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:" \
  "case CMD_SUSFS_SHOW_ENABLED_FEATURES:" \
  "case CMD_SUSFS_SHOW_VARIANT:" \
  "case CMD_SUSFS_SHOW_VERSION:"; do
  grep -R -Fq -- "$hook" "$KSU_TREE/kernel" ||
    fail "patched KernelSU is missing required enabled hook: $hook"
done
if grep -R -Fq -- "config KSU_SUSFS_SUS_MEMFD" "$KSU_TREE/kernel"; then
  fail "reverted sus_memfd support must stay absent"
fi

require_sha256 "fs/susfs.c" 952b0501ca42a464cdbec2ce64dffedc2e7c67df6a884a6f022b21a259f1837f
require_sha256 "include/linux/susfs.h" 05d4ec96ba75d459612d6269614bc7e1948c4e7b1ecd4dfaf47fbd4ec4a3fcfb
require_sha256 "include/linux/susfs_def.h" 4eef49b81b6d8320194284adf02987b7e89df81495f7cdf9de9b29072dd9d87a

require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KPROBES=y"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU=y"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU_SUSFS=y"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_SUS_PATH is not set"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_SUS_MOUNT is not set"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_SUS_KSTAT is not set"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG is not set"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set"
require_line "arch/arm64/configs/vayu_defconfig" "# CONFIG_KSU_SUSFS_SUS_MAP is not set"
if grep -Fqx -- "CONFIG_KSU_SUSFS_SUS_MEMFD=y" "$DEFCONFIG"; then
  fail "reverted sus_memfd support must stay disabled"
fi

require_line ".gitmodules" '[submodule "KernelSU-Next"]'
require_line ".gitmodules" $'\tpath = KernelSU-Next'
require_line ".gitmodules" $'\turl = https://github.com/KernelSU-Next/KernelSU-Next'
gitlink="$(git -C "$ROOT_DIR" ls-files -s -- KernelSU-Next)"
[[ "$gitlink" == "160000 $KERNELSU_NEXT_COMMIT 0"$'\t'"KernelSU-Next" ]] ||
  fail "KernelSU-Next must be a gitlink at the pinned commit"

require_line "drivers/Kconfig" 'source "drivers/kernelsu/Kconfig"'
require_line "drivers/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
require_line "fs/Makefile" 'obj-$(CONFIG_KSU_SUSFS) += susfs.o'
require_contains "kernel/sys.c" "susfs_spoof_uname"
require_contains "kernel/reboot.c" "ksu_handle_sys_reboot"
require_contains "security/selinux/avc.c" "susfs_is_avc_log_spoofing_enabled"
bash -n "$ROOT_DIR/scripts/prepare-ksu-susfs.sh"

compile_mode="${VERIFY_KERNEL_COMPILE:-auto}"
if [[ "$compile_mode" != 0 && -z "${KSU_SOURCE_DIR:-}" ]]; then
  git -C "$ROOT_DIR/KernelSU-Next" apply --check "$PATCH_FILE"
  git -C "$ROOT_DIR/KernelSU-Next" apply "$PATCH_FILE"
  PATCHED_ACTUAL=1
  OUT_DIR="$TEMP_DIR/out"
  make -s -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 vayu_defconfig
  for line in     "CONFIG_KSU=y"     "CONFIG_KSU_SUSFS=y"     "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"     "CONFIG_KSU_SUSFS_ENABLE_LOG=y"; do
    grep -Fqx -- "$line" "$OUT_DIR/.config" ||
      fail "generated config is missing $line"
  done
  make -s -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 -j2 fs/susfs.o
elif [[ "$compile_mode" == 1 ]]; then
  fail "VERIFY_KERNEL_COMPILE=1 requires the real pinned submodule"
else
  printf 'SKIP: kernel config/object compile not feasible with KSU_SOURCE_DIR override\n'
fi

printf 'PASS: KernelSU-Next v3.3.0 and SuSFS v2.2.0 integration verified\n'
