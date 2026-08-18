#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

repo_dir="$tmp_dir/repo"
bin_dir="$tmp_dir/bin"
clang_dir="$tmp_dir/clang"
anykernel_dir="$tmp_dir/AnyKernel3"
out_dir="$tmp_dir/out"
artifacts_dir="$tmp_dir/artifacts"
mkdir -p "$repo_dir/scripts" "$repo_dir/KernelSU-Next" "$bin_dir" "$clang_dir/bin" "$anykernel_dir/.git"

cp "$root_dir/build.sh" "$repo_dir/build.sh"
cp "$root_dir/scripts/build-versions.env" "$repo_dir/scripts/build-versions.env"
cp "$root_dir/scripts/prepare-ksu-susfs.sh" "$repo_dir/scripts/prepare-ksu-susfs.sh"
cp "$root_dir/scripts/package-anykernel.sh" "$repo_dir/scripts/package-anykernel.sh"

cat > "$bin_dir/make" <<'MAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
out_dir=''
for argument in "$@"; do
  case "$argument" in
    O=*) out_dir="${argument#O=}" ;;
  esac
done
[[ -n "$out_dir" ]] || exit 2
if [[ " $* " == *" vayu_defconfig "* ]]; then
  mkdir -p "$out_dir"
  printf 'CONFIG_KSU=y\nCONFIG_KSU_SUSFS=y\n' > "$out_dir/.config"
else
  mkdir -p "$out_dir/arch/arm64/boot"
  printf 'Image\n' > "$out_dir/arch/arm64/boot/Image"
  printf 'dtb\n' > "$out_dir/arch/arm64/boot/dtb.img"
  printf 'dtbo\n' > "$out_dir/arch/arm64/boot/dtbo.img"
fi
MAKE

cat > "$clang_dir/bin/clang" <<'CLANG'
#!/usr/bin/env bash
printf 'Neutron clang version 24.0.0git\n'
printf '17efc66a340e35ae03a18e34e7f267832fff7940\n'
CLANG
cat > "$clang_dir/bin/ld.lld" <<'LLD'
#!/usr/bin/env bash
printf 'Neutron LLD 24.0.0git\n'
printf '17efc66a340e35ae03a18e34e7f267832fff7940\n'
LLD
cat > "$bin_dir/git" <<'GIT'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *'rev-parse HEAD'*)
    if [[ "$*" == *AnyKernel3* ]]; then
      printf 'e4b1bb25ca2aabcfd57f694a5998d87130701b71\n'
    else
      printf '0123456789abcdef0123456789abcdef01234567\n'
    fi
    ;;
  *'apply --reverse --check'*) exit 1 ;;
  *'status --porcelain'*|*'apply --check'*|*' apply '*) exit 0 ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$bin_dir/make" "$bin_dir/git" "$clang_dir/bin/clang" "$clang_dir/bin/ld.lld"

cat > "$anykernel_dir/anykernel.sh" <<'AK'
kernel.string=Anymore
device.name1=vayu
device.name2=bhima
supported.versions=11 - 17
AK
printf 'stale archive\n' > "$anykernel_dir/old.zip"
printf 'ignored\n' > "$anykernel_dir/.git/ignored"

PATH="$bin_dir:$clang_dir/bin:$PATH" \
  CLANG_DIR="$clang_dir" \
  ANYKERNEL_DIR="$anykernel_dir" \
  OUT_DIR="$out_dir" \
  ARTIFACTS_DIR="$artifacts_dir" \
  JOBS=2 \
  KBUILD_BUILD_USER=contract-user \
  KBUILD_BUILD_HOST=contract-host \
  bash "$repo_dir/build.sh"

expected_zip="$artifacts_dir/Anymore-vayu-4.14.357+17-perf-0123456789ab-KSUNext-3.3.0.zip"
[[ -f "$expected_zip" ]] || fail 'expected deterministic Anymore ZIP was not created'
[[ "$(find "$artifacts_dir" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' ')" == 1 ]] ||
  fail 'packaging must leave exactly one ZIP artifact'
for artifact in Image dtb.img dtbo.img kernel.config build-info.txt; do
  [[ -s "$artifacts_dir/$artifact" ]] || fail "missing raw artifact: $artifact"
done
grep -Fqx 'Linux version 4.14.357+17-perf' "$artifacts_dir/build-info.txt" ||
  fail 'missing kernel release metadata'
grep -Fqx 'Neutron clang version 24.0.0git' "$artifacts_dir/build-info.txt" ||
  fail 'missing compiler metadata'
grep -Fqx 'KBUILD_BUILD_USER=contract-user' "$artifacts_dir/build-info.txt" ||
  fail 'missing build user metadata'
grep -Fqx 'KBUILD_BUILD_HOST=contract-host' "$artifacts_dir/build-info.txt" ||
  fail 'missing build host metadata'
for member in Image dtb.img dtbo.img; do
  unzip -Z1 "$expected_zip" | grep -Fqx "$member" ||
    fail "ZIP is missing $member"
done
if unzip -Z1 "$expected_zip" | grep -Eq '(^|/)\.git(/|$)|old\.zip'; then
  fail 'ZIP must not include Git state or old archives'
fi
printf 'PASS: build script honors overrides and creates a deterministic AnyKernel3 artifact\n'
