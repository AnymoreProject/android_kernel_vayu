#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VERSIONS_FILE="$ROOT_DIR/scripts/build-versions.env"
DEFCONFIG="$ROOT_DIR/arch/arm64/configs/vayu_defconfig"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

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

require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KPROBES=y"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU=y"
require_line "arch/arm64/configs/vayu_defconfig" "CONFIG_KSU_SUSFS=y"
if grep -Fqx -- "CONFIG_KSU_SUSFS_SUS_MEMFD=y" "$DEFCONFIG"; then
  fail "reverted sus_memfd support must stay disabled"
fi

require_line ".gitmodules" '[submodule "KernelSU-Next"]'
require_line ".gitmodules" $'\tpath = KernelSU-Next'
require_line ".gitmodules" $'\turl = https://github.com/KernelSU-Next/KernelSU-Next'
gitlink="$(git -C "$ROOT_DIR" ls-files -s -- KernelSU-Next)"
[[ "$gitlink" == "160000 $KERNELSU_NEXT_COMMIT 0"$'\t'"KernelSU-Next" ]] ||
  fail "KernelSU-Next must be a gitlink at the pinned commit"

[[ -L "$ROOT_DIR/drivers/kernelsu" ]] || fail "drivers/kernelsu must be a symlink"
[[ "$(readlink "$ROOT_DIR/drivers/kernelsu")" == "../KernelSU-Next/kernel" ]] ||
  fail "drivers/kernelsu has the wrong target"
require_line "drivers/Kconfig" 'source "drivers/kernelsu/Kconfig"'
require_line "drivers/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'

require_file "fs/susfs.c"
require_file "include/linux/susfs.h"
require_file "include/linux/susfs_def.h"
require_contains "include/linux/susfs.h" '#define SUSFS_VERSION "v2.2.0"'
require_line "fs/Makefile" 'obj-$(CONFIG_KSU_SUSFS) += susfs.o'
require_contains "kernel/sys.c" "ksu_handle_sys_reboot"
require_contains "security/selinux/avc.c" "susfs_is_avc_log_spoofing_enabled"
require_file "patches/KernelSU-Next/0001-susfs-2.2.0.patch"
require_file "scripts/prepare-ksu-susfs.sh"
require_contains "patches/KernelSU-Next/0001-susfs-2.2.0.patch" "config KSU_SUSFS"
if grep -R -Fq -- "config KSU_SUSFS_SUS_MEMFD"   "$ROOT_DIR/patches/KernelSU-Next" "$ROOT_DIR/include/linux" "$ROOT_DIR/fs/susfs.c"; then
  fail "reverted sus_memfd Kconfig/source must not be restored"
fi
bash -n "$ROOT_DIR/scripts/prepare-ksu-susfs.sh"

printf 'PASS: KernelSU-Next v3.3.0 and SuSFS v2.2.0 integration verified\n'
