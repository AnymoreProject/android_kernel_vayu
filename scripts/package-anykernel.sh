#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/build-versions.env"

: "${OUT_DIR:?OUT_DIR must be set}"
: "${ANYKERNEL_DIR:?ANYKERNEL_DIR must be set}"
: "${ARTIFACTS_DIR:?ARTIFACTS_DIR must be set}"

KERNEL_RELEASE="4.14.357+17-perf"
KERNEL_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
ZIP_NAME="Anymore-vayu-${KERNEL_RELEASE}-${KERNEL_SHA:0:12}-KSUNext-${KERNELSU_NEXT_VERSION#v}.zip"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -d "$ANYKERNEL_DIR/.git" ]] || die "AnyKernel3 must be a Git working tree"
[[ "$(git -C "$ANYKERNEL_DIR" rev-parse HEAD)" == "$ANYKERNEL3_COMMIT" ]] ||
  die "AnyKernel3 is not at pinned commit $ANYKERNEL3_COMMIT"
[[ -z "$(git -C "$ANYKERNEL_DIR" status --porcelain)" ]] ||
  die 'AnyKernel3 working tree is not clean'

metadata="$ANYKERNEL_DIR/anykernel.sh"
[[ -f "$metadata" ]] || die 'AnyKernel3 metadata file is missing'
for required_metadata in 'device.name1=vayu' 'device.name2=bhima' 'supported.versions=11 - 17'; do
  grep -Fq -- "$required_metadata" "$metadata" ||
    die "AnyKernel3 metadata is missing: $required_metadata"
done

for output in Image dtb.img dtbo.img; do
  [[ -s "$OUT_DIR/arch/arm64/boot/$output" ]] ||
    die "required build output is missing: $output"
done
for required_artifact in kernel.config build-info.txt; do
  [[ -s "$ARTIFACTS_DIR/$required_artifact" ]] ||
    die "required artifact is missing: $required_artifact"
done
command -v zip >/dev/null 2>&1 || die 'zip is required to package AnyKernel3'

mkdir -p "$ARTIFACTS_DIR"
for output in Image dtb.img dtbo.img; do
  cp "$OUT_DIR/arch/arm64/boot/$output" "$ARTIFACTS_DIR/$output"
done
find "$ARTIFACTS_DIR" -maxdepth 1 -type f -name '*.zip' -delete

stage_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

cp -a "$ANYKERNEL_DIR/." "$stage_dir/"
rm -rf "$stage_dir/.git"
find "$stage_dir" -type f -name '*.zip' -delete
for output in Image dtb.img dtbo.img; do
  cp "$OUT_DIR/arch/arm64/boot/$output" "$stage_dir/$output"
done

(
  cd "$stage_dir"
  zip -q -r "$ARTIFACTS_DIR/$ZIP_NAME" . -x '.git/*' '*.zip'
)

[[ -s "$ARTIFACTS_DIR/$ZIP_NAME" ]] || die 'AnyKernel3 ZIP was not created'
printf 'Created %s\n' "$ARTIFACTS_DIR/$ZIP_NAME"
