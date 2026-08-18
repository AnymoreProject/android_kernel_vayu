#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_rejected() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "accepted $description"
  fi
}

repo_dir="$tmp_dir/repo"
bin_dir="$tmp_dir/bin"
clang_dir="$tmp_dir/clang"
anykernel_dir="$tmp_dir/AnyKernel3"
out_dir="$tmp_dir/out"
artifacts_dir="$tmp_dir/artifacts"
mkdir -p "$repo_dir/scripts" "$repo_dir/KernelSU-Next" "$bin_dir" "$clang_dir/bin" "$anykernel_dir/.git" "$artifacts_dir"

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
  for output in Image dtb.img dtbo.img; do
    [[ "${FAKE_MISSING_OUTPUT:-}" == "$output" ]] && continue
    printf '%s\n' "$output" > "$out_dir/arch/arm64/boot/$output"
  done
fi
MAKE

cat > "$clang_dir/bin/clang" <<'CLANG'
#!/usr/bin/env bash
printf 'Neutron clang version %s (https://github.com/llvm/llvm-project.git 17efc66a340e35ae03a18e34e7f267832fff7940)\n' "${FAKE_CLANG_VERSION:-24.0.0git}"
CLANG
cat > "$clang_dir/bin/ld.lld" <<'LLD'
#!/usr/bin/env bash
printf 'Neutron LLD %s (https://github.com/llvm/llvm-project.git 17efc66a340e35ae03a18e34e7f267832fff7940) (compatible with GNU linkers)\n' "${FAKE_LLD_VERSION:-24.0.0}"
LLD
cat > "$bin_dir/git" <<'GIT'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *KernelSU-Next*'rev-parse HEAD'*)
    printf '3b18216f71df189ab3d1b1ce0bdb21be1268e771\n'
    ;;
  *AnyKernel3*'rev-parse HEAD'*)
    printf 'e4b1bb25ca2aabcfd57f694a5998d87130701b71\n'
    ;;
  *'rev-parse HEAD'*)
    printf '0123456789abcdef0123456789abcdef01234567\n'
    ;;
  *'apply --reverse --check'*) exit 1 ;;
  *'status --porcelain'*|*'apply --check'*|*' apply '*) exit 0 ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$bin_dir/make" "$bin_dir/git" "$clang_dir/bin/clang" "$clang_dir/bin/ld.lld"

write_metadata() {
  cat > "$anykernel_dir/anykernel.sh" <<'AK'
kernel.string=Anymore
device.name1=vayu
device.name2=bhima
supported.versions=11 - 17
AK
}

run_build() {
  env \
    PATH="$bin_dir:$clang_dir/bin:$PATH" \
    CLANG_DIR="$clang_dir" \
    ANYKERNEL_DIR="$anykernel_dir" \
    OUT_DIR="$out_dir" \
    ARTIFACTS_DIR="$artifacts_dir" \
    JOBS=2 \
    KBUILD_BUILD_USER=contract-user \
    KBUILD_BUILD_HOST=contract-host \
    "$@" bash "$repo_dir/build.sh"
}

write_metadata
printf 'stale archive\n' > "$anykernel_dir/old.zip"
printf 'ignored\n' > "$anykernel_dir/.git/ignored"
printf 'old artifact\n' > "$artifacts_dir/old.zip"
run_build
expected_zip="$artifacts_dir/Anymore-vayu-4.14.357+17-perf-0123456789ab-KSUNext-3.3.0.zip"
[[ -f "$expected_zip" ]] || fail 'expected deterministic Anymore ZIP was not created'
[[ ! -e "$artifacts_dir/old.zip" ]] || fail 'pre-existing artifact ZIP was not removed'
[[ "$(find "$artifacts_dir" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' ')" == 1 ]] ||
  fail 'packaging must leave exactly one ZIP artifact'
for artifact in Image dtb.img dtbo.img kernel.config build-info.txt; do
  [[ -s "$artifacts_dir/$artifact" ]] || fail "missing raw artifact: $artifact"
done
grep -Fqx 'Linux version 4.14.357+17-perf' "$artifacts_dir/build-info.txt" ||
  fail 'missing kernel release metadata'
grep -Fqx 'Neutron clang version 24.0.0git (https://github.com/llvm/llvm-project.git 17efc66a340e35ae03a18e34e7f267832fff7940)' "$artifacts_dir/build-info.txt" ||
  fail 'actual verified clang output was not recorded'
grep -Fqx 'Neutron LLD 24.0.0 (https://github.com/llvm/llvm-project.git 17efc66a340e35ae03a18e34e7f267832fff7940) (compatible with GNU linkers)' "$artifacts_dir/build-info.txt" ||
  fail 'actual verified lld output was not recorded'
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

expect_rejected 'a wrong clang identity' run_build FAKE_CLANG_VERSION=23.0.0git
expect_rejected 'a wrong lld identity' run_build FAKE_LLD_VERSION=23.0.0
for output in Image dtb.img dtbo.img; do
  expect_rejected "a missing $output" run_build "FAKE_MISSING_OUTPUT=$output"
done

cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name2=bhima
supported.versions=11 - 17
AK
expect_rejected 'missing vayu metadata' run_build
cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name1=venus
device.name2=bhima
supported.versions=11 - 17
AK
expect_rejected 'invalid vayu metadata' run_build
cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name1=vayu
supported.versions=11 - 17
AK
expect_rejected 'missing bhima metadata' run_build
cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name1=vayu
device.name2=alioth
supported.versions=11 - 17
AK
expect_rejected 'invalid bhima metadata' run_build
cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name1=vayu
device.name2=bhima
AK
expect_rejected 'missing Android version metadata' run_build
cat > "$anykernel_dir/anykernel.sh" <<'AK'
device.name1=vayu
device.name2=bhima
supported.versions=12 - 17
AK
expect_rejected 'invalid Android version metadata' run_build

printf 'PASS: reproducible build and AnyKernel3 packaging contracts hold\n'
