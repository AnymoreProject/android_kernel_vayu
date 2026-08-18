# Docker and KernelSU-Next build design

Date: 2026-08-18  
Target: `thirteenth13/android_kernel_vayu_ap`, branch `16`

## Goal

Provide one reproducible build path for local Docker and GitHub Actions that produces a flashable AnyKernel3 ZIP for POCO X3 Pro (vayu/bhima). The build must retain the current `16` kernel history, use the compiler named in the maintainer's current changelog, and add KernelSU-Next with SUSFS without merging the divergent `16-ksun` kernel branch wholesale.

## Source baselines

- Kernel: the fork's current `16` branch, preserving its Linux 4.14.357-openela and device changes.
- KernelSU integration reference: upstream `AnymoreProject/android_kernel_vayu:16-ksun`.
- KernelSU source: the `KernelSU-Next/KernelSU-Next` submodule pinned to the same gitlink revision used by upstream `16-ksun`.
- Packaging: `AnymoreProject/AnyKernel3:master`, pinned to a resolved commit during implementation.
- Compiler: Google's Linux x86 AOSP Clang `clang-r596125` (22.0.2), pinned to AOSP prebuilt commit `8b6826407e25a197d7cf7ceacab0bf67c11173de`.

Pins are explicit inputs so a future upstream branch movement cannot silently alter an existing build.

## KernelSU-Next integration

Do not merge or rebase `16-ksun` into `16`: the branches have substantially diverged. Instead, port only the KernelSU-Next integration surface from `16-ksun`:

1. Add the KernelSU-Next submodule and its build-system wiring.
2. Port the minimal Kconfig, Makefile, syscall/hook, SELinux and SUSFS changes required by that pinned KernelSU-Next revision.
3. Enable `CONFIG_KSU=y` and `CONFIG_KSU_SUSFS=y` in `arch/arm64/configs/vayu_defconfig`.
4. Preserve all unrelated files and settings from `16`.
5. Verify the generated `.config` contains both flags and that the compiled kernel identifies KernelSU-Next.

The port will be derived file-by-file from the upstream integration rather than by selecting all 640 branch-specific commits.

## Build interface

`build.sh` remains the canonical build program and continues to support native Linux execution. Hard-coded `/root` paths become overridable environment variables with compatible defaults:

- `CLANG_DIR`
- `ANYKERNEL_DIR`
- `OUT_DIR`
- `ARTIFACTS_DIR`
- `JOBS`
- `KBUILD_BUILD_USER`
- `KBUILD_BUILD_HOST`

The script will fail fast when the compiler version is not Clang 22.0.2, a required submodule is missing, configuration generation fails, or any required output is absent. It will copy `Image`, `dtbo.img`, and optional `dtb.img` into a clean AnyKernel3 worktree and write exactly one timestamp-independent ZIP name suitable for CI. The outer artifact directory is never deleted by the kernel clean step.

## Docker layout

- `Dockerfile`: Ubuntu-based build environment with pinned AOSP Clang 22.0.2 and required kernel build packages.
- `.dockerignore`: excludes Git metadata, `out/`, `artifacts/`, caches, and previously generated archives.
- `docker-compose.yml`: mounts the source read-only where practical, mounts writable `out/`, `artifacts/`, and a persistent ccache volume, then invokes the canonical build script.
- `scripts/docker-build.sh`: small host wrapper that creates output directories, initializes submodules, and runs Compose consistently on Linux, macOS, and Docker Desktop.

The container runs as the invoking user where supported so local artifacts are not left owned by root.

## GitHub Actions

`.github/workflows/docker-build.yml` will:

- run on `workflow_dispatch`, pull requests targeting `16`, and pushes to the feature branch or `16`;
- check out recursively with submodules;
- build the same Dockerfile used locally;
- restore Docker layer and ccache data where GitHub's cache permits;
- run the container build;
- validate that there is exactly one non-empty ZIP plus non-empty `Image` and `dtbo.img`;
- upload the ZIP and raw images as a GitHub Actions artifact;
- retain artifacts for 14 days.

The workflow receives read-only repository permissions and does not publish releases or container images.

## Validation

Before opening the implementation pull request:

1. Validate Dockerfile and Compose configuration parsing.
2. Build the image and assert `clang --version` reports 22.0.2.
3. Run defconfig generation and assert `CONFIG_KSU=y` and `CONFIG_KSU_SUSFS=y`.
4. Run a full kernel build when runner resources allow it.
5. Inspect the AnyKernel ZIP for `Image`, `dtbo.img`, updater scripts, and absence of nested Git metadata.
6. Confirm local and Actions commands invoke the same script and use the same pins.

A GitHub-hosted runner may exceed its time or disk limit during a full Android kernel build. Such infrastructure exhaustion is reported distinctly from compilation failure; the local Docker path remains the authoritative full-build route.

## Documentation

Add `DOCKER.md` covering prerequisites, the one-command local build, output locations, cache cleanup, manual GitHub Actions dispatch, compiler and source pins, and the warning that a successfully compiled kernel still requires device-side testing before flashing.
