# Docker and KernelSU-Next build design

Date: 2026-08-18  
Target: `thirteenth13/android_kernel_vayu_ap`, branch `16`

## Goal

Provide one reproducible build path for local Docker and GitHub Actions that produces a flashable AnyKernel3 ZIP for POCO X3 Pro (vayu/bhima). The output must reproduce the maintainer's 2026-08-09 release family: Linux `4.14.357+17-perf`, Android 11–17 support, Neutron-Clang 24, KernelSU-Next 3.3.0, and SuSFS 2.2.0.

## Release reference

The supplied reference archive is `[Vayu]-Anymore-20260809.zip` with SHA-256:

`7EDC8637E4B76CE03F4C67426024EF71EA2C0DA1ABF353A9EE59423372664E3A`

It is evidence for output structure and build identity, not a source of executable build instructions. Inspection confirms:

- `Image`, `dtb.img`, and `dtbo.img`;
- an AnyKernel3 package using `tools/kyriepatch.sh`;
- device checks for `vayu` and `bhima`;
- supported Android versions `11 - 17`;
- embedded kernel identity `Linux version 4.14.357+17-perf`;
- Neutron Clang and LLD `24.0.0git`, based on LLVM commit `17efc66a340e35ae03a18e34e7f267832fff7940`.

The project will not copy opaque binaries from this archive into new builds.

## Source baselines

- Kernel: the fork's current `16` branch, preserving the maintainer's Android 17, LineageOS 20 merge, clock, WLAN GTK, and alarmtimer changes.
- KernelSU integration reference: upstream `AnymoreProject/android_kernel_vayu:16-ksun`, used only to identify device-specific integration points.
- KernelSU source: official `KernelSU-Next/KernelSU-Next` release/tag matching version 3.3.0, pinned by commit.
- SuSFS source: official 2.2.0-compatible integration from `sidex15/susfs4ksu`, pinned by commit.
- Packaging: `AnymoreProject/AnyKernel3:master`, pinned to a resolved commit and verified against the supplied ZIP layout.
- Compiler: a pinned Neutron-Clang prebuilt whose `clang --version` and `ld.lld --version` identify LLVM commit `17efc66a340e35ae03a18e34e7f267832fff7940`.

All moving references are resolved to immutable commits and checksums in the implementation so upstream changes cannot silently alter a build.

## KernelSU-Next and SuSFS integration

Do not merge or rebase `16-ksun` into `16`: the branches have substantially diverged. Instead:

1. Add KernelSU-Next 3.3.0 using its supported non-GKI integration for Linux 4.14.
2. Port only the device-specific Kconfig, Makefile, syscall/hook and SELinux integration points required from `16-ksun`.
3. Integrate SuSFS 2.2.0 using the compatibility level required by KernelSU-Next 3.3.0.
4. Keep the release's reverted `sus_memfd` behavior; do not re-enable that driver change indirectly.
5. Enable `CONFIG_KSU=y` and `CONFIG_KSU_SUSFS=y` in `arch/arm64/configs/vayu_defconfig`.
6. Preserve all unrelated files and settings from `16`.
7. Verify the generated `.config`, build log, and resulting kernel identity.

The implementation will be derived file-by-file and reviewed as a focused integration, not selected as hundreds of unrelated branch commits.

## Build interface

`build.sh` remains the canonical build program and supports native Linux execution. Hard-coded `/root` paths become overridable environment variables with compatible defaults:

- `CLANG_DIR`
- `ANYKERNEL_DIR`
- `OUT_DIR`
- `ARTIFACTS_DIR`
- `JOBS`
- `KBUILD_BUILD_USER`
- `KBUILD_BUILD_HOST`

The script fails fast when compiler identity does not match the pinned Neutron-Clang 24 build, submodules are missing, configuration fails, or required output is absent. It copies `Image`, `dtb.img`, and `dtbo.img` into a clean AnyKernel3 worktree and writes one deterministic ZIP basename containing the kernel version and source commit. The artifacts directory is never removed by the kernel clean step.

## Docker layout

- `Dockerfile`: Ubuntu-based environment with the pinned Neutron-Clang 24 toolchain and kernel build dependencies.
- `.dockerignore`: excludes Git metadata, `out/`, `artifacts/`, caches, and generated archives.
- `docker-compose.yml`: mounts source and writable `out/`, `artifacts/`, and persistent ccache storage, then invokes the canonical build script.
- `scripts/docker-build.sh`: host wrapper that prepares directories, verifies submodules, and runs Compose consistently on Linux, macOS, and Docker Desktop.

The container runs as the invoking user where supported so local artifacts are not owned by root.

## Packaging requirements

The generated flashable ZIP must match the functional structure of the supplied reference:

- root-level `Image`, `dtb.img`, `dtbo.img`, `anykernel.sh`, and `banner`;
- AnyKernel3 updater files and tools, including KyriePatch;
- device checks for vayu and bhima;
- Android support declaration `11 - 17`;
- no nested Git metadata, stale ZIPs, or binaries copied from the supplied reference archive.

MIUI uses the normal package plus `dtbo.img`. HyperOS/OxygenOS packaging differences remain explicit and must not be guessed; this scope produces the normal vayu/bhima package and separately uploads `dtbo.img`.

## GitHub Actions

`.github/workflows/docker-build.yml` will:

- run on `workflow_dispatch`, pull requests targeting `16`, and pushes to the feature branch or `16`;
- check out recursively with pinned submodules;
- build the same Dockerfile used locally;
- restore Docker layer and ccache data where supported;
- run the canonical container build;
- validate one non-empty ZIP and non-empty `Image`, `dtb.img`, and `dtbo.img`;
- upload the ZIP and raw images as one GitHub Actions artifact retained for 14 days.

The workflow has read-only repository permissions and does not publish releases or container images.

## Validation

Before opening the implementation pull request:

1. Validate Dockerfile and Compose parsing.
2. Assert the toolchain reports Neutron Clang/LLD 24 and LLVM commit `17efc66a340e35ae03a18e34e7f267832fff7940`.
3. Generate defconfig and assert `CONFIG_KSU=y` and `CONFIG_KSU_SUSFS=y`.
4. Run a full kernel build when runner resources allow.
5. Confirm the built Image reports `4.14.357+17-perf` and the expected compiler identity.
6. Inspect the ZIP for required images, updater scripts, vayu/bhima checks, Android 11–17, and absence of Git metadata.
7. Confirm local and Actions commands invoke the same build script and immutable pins.

GitHub runner time or disk exhaustion is reported separately from compilation failure; the local Docker path remains available for a full build.

## Documentation

Add `DOCKER.md` covering prerequisites, one-command local build, output locations, cache cleanup, Actions dispatch, source/toolchain pins, reference archive checksum, and the warning that compilation does not replace device-side boot and flashing tests.
