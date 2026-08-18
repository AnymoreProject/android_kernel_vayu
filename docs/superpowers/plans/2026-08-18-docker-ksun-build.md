# Docker KernelSU-Next Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the current Anymore vayu `16` kernel reproducibly with Neutron-Clang 24, KernelSU-Next 3.3.0, SuSFS 2.2.0, Docker Compose, and a GitHub Actions artifact.

**Architecture:** Keep `build.sh` as the single build entrypoint. Port only the KSU/SuSFS integration surface onto current `16`, pin every external source, and have local Compose and Actions call the same container and verification scripts.

**Tech Stack:** Linux 4.14 Kbuild, Bash, Docker/Compose, Neutron LLVM/Clang 24, KernelSU-Next, SuSFS, AnyKernel3, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-08-18-docker-ksun-build-design.md`

## Global Constraints

- Kernel baseline remains current branch `16`, including Linux `4.14.357+17-perf` and the 2026-08-09 maintainer changes.
- Compiler must identify Neutron Clang and LLD `24.0.0git` at LLVM commit `17efc66a340e35ae03a18e34e7f267832fff7940`.
- KernelSU-Next must be version 3.3.0; SuSFS must be version 2.2.0.
- `CONFIG_KSU=y` and `CONFIG_KSU_SUSFS=y` must be present in the generated configuration.
- The reverted `sus_memfd` behavior stays reverted.
- Packaging must use pinned `AnymoreProject/AnyKernel3` content and produce `Image`, `dtb.img`, `dtbo.img`, and one flashable ZIP.
- The supplied release archive is a test oracle only; none of its binaries may enter a new artifact.
- Generated packaging declares vayu/bhima and Android 11–17.
- GitHub Actions receives read-only repository permissions and retains artifacts for 14 days.

---

### Task 1: Add deterministic release-verification tests

**Files:**
- Create: `scripts/verify-build.sh`
- Create: `tests/build/verify-build-test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `ARTIFACTS_DIR`, `EXPECTED_LLVM_COMMIT`, `EXPECTED_KERNEL_RELEASE`
- Produces: `scripts/verify-build.sh [artifact-directory]`, exit 0 only for a valid build

- [ ] **Step 1: Write the failing shell test**

Create fixtures in a temporary directory and assert failure for missing files, duplicate ZIPs, wrong compiler identity, absent KSU flags, and ZIPs lacking `Image`, `dtb.img`, or `dtbo.img`. The success fixture must contain exactly one ZIP and mock text files with:

```text
Linux version 4.14.357+17-perf
Neutron clang version 24.0.0git
17efc66a340e35ae03a18e34e7f267832fff7940
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
```

Run:

```bash
bash tests/build/verify-build-test.sh
```

Expected: FAIL because `scripts/verify-build.sh` does not exist.

- [ ] **Step 2: Implement the verifier**

Implement strict Bash mode, exactly-one-ZIP validation, non-empty raw-image checks, `unzip -Z1` membership checks, and fixed-string checks against `build-info.txt` and `kernel.config`. Accept the artifact directory as `$1`, defaulting to `artifacts`.

- [ ] **Step 3: Run the verifier test**

Run: `bash tests/build/verify-build-test.sh`  
Expected: PASS with each negative fixture rejected and the success fixture accepted.

- [ ] **Step 4: Ignore generated state**

Add these entries without removing existing patterns:

```gitignore
/out/
/artifacts/
/.ccache/
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore scripts/verify-build.sh tests/build/verify-build-test.sh
git commit -m "test: add kernel artifact verification"
```

### Task 2: Integrate KernelSU-Next 3.3.0 and SuSFS 2.2.0 on current `16`

**Files:**
- Create: `.gitmodules`
- Create: `KernelSU-Next` (gitlink)
- Modify: `arch/arm64/configs/vayu_defconfig`
- Modify: `drivers/Makefile`
- Modify: `drivers/Kconfig`
- Create or modify: `drivers/kernelsu` integration link/directory according to the upstream `16-ksun` layout
- Modify: only the exact `fs/`, `include/linux/`, `security/`, syscall, and SELinux files selected by the pinned SuSFS 2.2.0 patch set
- Create: `tests/build/verify-ksu-integration.sh`

**Interfaces:**
- Consumes: upstream refs `AnymoreProject/android_kernel_vayu:16` and `:16-ksun`; official KernelSU-Next 3.3.0 and SuSFS 2.2.0 pins
- Produces: a current-`16` source tree whose `vayu_defconfig` enables KSU and SuSFS

- [ ] **Step 1: Record immutable upstream pins**

Resolve the KernelSU-Next 3.3.0 tag, SuSFS 2.2.0-compatible patch commit, AnyKernel3 commit, Neutron prebuilt commit/archive checksum, and `16-ksun` gitlink. Store them as literal values in `scripts/build-versions.env` using:

```bash
KERNELSU_VERSION=3.3.0
KERNELSU_COMMIT=<resolved 40-character commit>
SUSFS_VERSION=2.2.0
SUSFS_COMMIT=<resolved 40-character commit>
ANYKERNEL_COMMIT=<resolved 40-character commit>
NEUTRON_LLVM_COMMIT=17efc66a340e35ae03a18e34e7f267832fff7940
NEUTRON_ARCHIVE_SHA256=<resolved 64-character checksum>
```

Replace each angle-bracket value with the verified immutable value before committing; the verification script rejects non-hex pins.

- [ ] **Step 2: Write the failing integration test**

`tests/build/verify-ksu-integration.sh` must check:

```bash
grep -qx 'CONFIG_KSU=y' arch/arm64/configs/vayu_defconfig
grep -qx 'CONFIG_KSU_SUSFS=y' arch/arm64/configs/vayu_defconfig
git submodule status KernelSU-Next
test -f KernelSU-Next/kernel/Kconfig
! git grep -n 'CONFIG_KSU_SUSFS_SUS_MEMFD=y' -- arch/arm64/configs/vayu_defconfig
```

It must also validate every pin in `scripts/build-versions.env`.

Run: `bash tests/build/verify-ksu-integration.sh`  
Expected: FAIL on the unmodified `16` baseline.

- [ ] **Step 3: Create a focused upstream integration patch**

Fetch `upstream/16-ksun`, inspect its KSU-related merge base, and construct a patch containing only KernelSU/SuSFS integration paths. Explicitly exclude scheduler, device-tree, WLAN, clock, alarmtimer, kernel-version, and unrelated filesystem changes. Review:

```bash
git diff --stat 16...upstream/16-ksun -- .gitmodules KernelSU-Next drivers/kernelsu drivers/Kconfig drivers/Makefile arch/arm64/configs/vayu_defconfig fs include/linux security
git diff --check
```

- [ ] **Step 4: Apply current official versions**

Pin the submodule to KernelSU-Next 3.3.0, apply the official SuSFS 2.2.0 Linux-4.14 patches, port the minimal `16-ksun` hooks, and enable the two required config flags. Resolve conflicts in favor of current `16` except where the official KSU/SuSFS integration requires a hook.

- [ ] **Step 5: Verify integration and configuration**

Run:

```bash
bash tests/build/verify-ksu-integration.sh
make O=out ARCH=arm64 vayu_defconfig
grep -E '^(CONFIG_KSU|CONFIG_KSU_SUSFS)=' out/.config
git diff --check
```

Expected: test passes and both generated flags equal `y`.

- [ ] **Step 6: Commit**

```bash
git add .gitmodules KernelSU-Next scripts/build-versions.env tests/build/verify-ksu-integration.sh arch/arm64/configs/vayu_defconfig drivers fs include security
git commit -m "feat: integrate KernelSU Next 3.3 and SuSFS 2.2"
```

### Task 3: Make the native build deterministic and package the reference layout

**Files:**
- Modify: `build.sh`
- Create: `scripts/package-anykernel.sh`
- Create: `tests/build/build-script-test.sh`

**Interfaces:**
- Consumes: variables from `scripts/build-versions.env`; compiled outputs under `OUT_DIR`
- Produces: raw images, `kernel.config`, `build-info.txt`, and one ZIP under `ARTIFACTS_DIR`

- [ ] **Step 1: Write failing build-script contract tests**

Use temporary mock `make`, `clang`, `ld.lld`, and AnyKernel directories to assert:

- environment overrides replace every `/root` default;
- wrong compiler identity stops before `make`;
- missing `dtb.img` or `dtbo.img` fails packaging;
- successful packaging creates one deterministic ZIP and raw images;
- `anykernel.sh` contains vayu, bhima, and `supported.versions=11 - 17`;
- archive contents exclude `.git` and old ZIP files.

Run: `bash tests/build/build-script-test.sh`  
Expected: FAIL against the existing script.

- [ ] **Step 2: Refactor `build.sh`**

Use `set -Eeuo pipefail`; source `scripts/build-versions.env`; default paths through `${VAR:-default}`; quote paths; use `JOBS=${JOBS:-$(nproc)}`; verify both compiler binaries; call `make` with the existing LLVM flags; save `out/.config`; write compiler, kernel, source, and dependency pins to `build-info.txt`.

- [ ] **Step 3: Implement isolated packaging**

`scripts/package-anykernel.sh` accepts `OUT_DIR ANYKERNEL_DIR ARTIFACTS_DIR`, resets the AnyKernel worktree to its pinned commit, copies the three images, checks metadata, and creates:

```text
Anymore-vayu-4.14.357+17-perf-<12-char-kernel-sha>-KSUNext-3.3.0.zip
```

Copy the three images, `kernel.config`, and `build-info.txt` alongside the ZIP.

- [ ] **Step 4: Run contract tests**

Run:

```bash
bash tests/build/build-script-test.sh
bash tests/build/verify-build-test.sh
bash tests/build/verify-ksu-integration.sh
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add build.sh scripts/package-anykernel.sh tests/build/build-script-test.sh
git commit -m "build: make kernel packaging reproducible"
```

### Task 4: Add the pinned Docker and Compose build

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `docker-compose.yml`
- Create: `scripts/docker-build.sh`
- Create: `tests/build/docker-config-test.sh`

**Interfaces:**
- Consumes: repository source, `scripts/build-versions.env`, Docker BuildKit
- Produces: image target `kernel-builder` and one-command `scripts/docker-build.sh`

- [ ] **Step 1: Write failing static Docker tests**

Check that the Dockerfile verifies the Neutron archive checksum, invokes `clang --version`, has no floating `:latest` base, and declares a non-root build user. Check Compose mounts `out`, `artifacts`, and ccache, and invokes `./build.sh`.

Run: `bash tests/build/docker-config-test.sh`  
Expected: FAIL because Docker files are absent.

- [ ] **Step 2: Implement the Dockerfile**

Use a digest-pinned Ubuntu base, install the exact kernel build dependencies without recommended packages, fetch the pinned Neutron archive, verify `NEUTRON_ARCHIVE_SHA256`, unpack it to `/opt/neutron`, and fail the image build unless compiler output contains both `24.0.0git` and the required LLVM commit.

- [ ] **Step 3: Implement Compose and wrapper**

Compose passes host UID/GID, mounts source, named ccache, `./out:/workspace/out`, and `./artifacts:/workspace/artifacts`. The wrapper checks Docker Compose availability, initializes submodules recursively, creates writable directories, and executes `docker compose build kernel-builder` then `docker compose run --rm kernel-builder`.

- [ ] **Step 4: Validate configuration and toolchain**

Run:

```bash
bash tests/build/docker-config-test.sh
docker compose config --quiet
docker build --target kernel-builder -t anymore-vayu-builder:test .
docker run --rm anymore-vayu-builder:test sh -c 'clang --version && ld.lld --version'
```

Expected: all pass; compiler output contains Neutron 24 and `17efc66a340e35ae03a18e34e7f267832fff7940`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore docker-compose.yml scripts/docker-build.sh tests/build/docker-config-test.sh
git commit -m "build: add pinned Docker kernel environment"
```

### Task 5: Add GitHub Actions and user documentation

**Files:**
- Create: `.github/workflows/docker-build.yml`
- Create: `tests/build/workflow-test.sh`
- Create: `DOCKER.md`
- Modify: `README`

**Interfaces:**
- Consumes: `Dockerfile`, `docker-compose.yml`, `scripts/docker-build.sh`, `scripts/verify-build.sh`
- Produces: manual/PR/push CI artifact named `anymore-vayu-kernel`

- [ ] **Step 1: Write failing workflow tests**

Validate triggers, `permissions: contents: read`, recursive checkout, Docker layer cache, ccache, invocation of the same container build, verifier execution, artifact retention `14`, and upload paths for ZIP/Image/dtb/dtbo/build metadata.

Run: `bash tests/build/workflow-test.sh`  
Expected: FAIL before the workflow exists.

- [ ] **Step 2: Implement the workflow**

Use pinned major versions of official GitHub actions, BuildKit cache, recursive checkout, a disk-space preflight, container build/run, `scripts/verify-build.sh artifacts`, and `actions/upload-artifact` with `if-no-files-found: error` and `retention-days: 14`.

- [ ] **Step 3: Write operational documentation**

`DOCKER.md` must include:

```bash
git submodule update --init --recursive
./scripts/docker-build.sh
```

Document output paths, cache cleanup, manual Actions dispatch, all immutable dependency pins, reference ZIP checksum, normal-package scope, separate `dtbo.img`, and device-testing/backup warnings. Add a short Docker build link to `README`.

- [ ] **Step 4: Run all fast tests**

```bash
bash tests/build/verify-build-test.sh
bash tests/build/verify-ksu-integration.sh
bash tests/build/build-script-test.sh
bash tests/build/docker-config-test.sh
bash tests/build/workflow-test.sh
docker compose config --quiet
git diff --check
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/docker-build.yml tests/build/workflow-test.sh DOCKER.md README
git commit -m "ci: publish Docker kernel build artifacts"
```

### Task 6: Perform the full build and prepare the pull request

**Files:**
- Verify: `artifacts/Anymore-vayu-*.zip`
- Verify: `artifacts/Image`
- Verify: `artifacts/dtb.img`
- Verify: `artifacts/dtbo.img`
- Verify: `artifacts/kernel.config`
- Verify: `artifacts/build-info.txt`

**Interfaces:**
- Consumes: completed Tasks 1–5
- Produces: verified branch and draft pull request to `thirteenth13/android_kernel_vayu_ap:16`

- [ ] **Step 1: Run the full Docker build**

```bash
./scripts/docker-build.sh
```

Expected: exit 0 and one complete artifact set.

- [ ] **Step 2: Verify artifacts**

```bash
scripts/verify-build.sh artifacts
unzip -Z1 artifacts/Anymore-vayu-*.zip
sha256sum artifacts/*
```

Expected: verifier passes; ZIP contains the three images and updater layout.

- [ ] **Step 3: Compare identity with the reference**

Confirm `build-info.txt` reports `4.14.357+17-perf`, Neutron 24 at the required LLVM commit, KernelSU-Next 3.3.0, and SuSFS 2.2.0. Differences in timestamps and binary hashes are expected; version, configuration, and package structure must match.

- [ ] **Step 4: Confirm branch cleanliness and history**

```bash
git status --short
git log --oneline --decorate -6
git diff --check 16...HEAD
```

Expected: no untracked build products; focused commits only.

- [ ] **Step 5: Push and open a draft PR**

Push `codex/docker-ksun-build` and open a draft PR targeting `16`. The description lists dependency pins, local command, Actions artifact, validation results, and the remaining device boot/flash test.
