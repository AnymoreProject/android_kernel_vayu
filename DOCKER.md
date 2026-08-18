# Reproducible Docker build

This repository builds the Anymore Project kernel for POCO X3 Pro (vayu/bhima) through the same Docker Compose path locally and in GitHub Actions.

## Prerequisites

Install Git, Docker Engine or Docker Desktop, and Docker Compose v2. Allow at least 30 GiB of free disk space. On Linux, configure Docker so your user can run it without `sudo`.

Clone the repository, select the intended branch, and initialize every submodule:

```bash
git submodule update --init --recursive
```

## Build locally

Run the canonical wrapper from the repository root:

```bash
./scripts/docker-build.sh
```

The wrapper builds the pinned container and runs `./build.sh` inside it. Generated kernel objects are written to `out/`. User-facing files are written to `artifacts/`:

- one `Anymore-vayu-*.zip` normal AnyKernel package;
- `Image`, `dtb.img`, and `dtbo.img`;
- `kernel.config` and `build-info.txt`.

Validate an existing result with:

```bash
EXPECTED_LLVM_COMMIT=17efc66a340e35ae03a18e34e7f267832fff7940 \
EXPECTED_KERNEL_RELEASE=4.14.357+17-perf \
./scripts/verify-build.sh artifacts
```

## Caches and cleanup

Compose keeps compiler results in the named `ccache` volume. Remove stopped containers and that cache with:

```bash
docker compose down --volumes
```

The generated `out/` and `artifacts/` directories are separate and can be removed when their contents are no longer needed.

## GitHub Actions

Open **Actions → Docker Kernel Build → Run workflow** and select the branch to start a manual build. The workflow also runs for pull requests targeting `16` and pushes to `16` or `codex/docker-ksun-build`. Download the `anymore-vayu-kernel` artifact from the completed run; GitHub retains it for 14 days.

The workflow has read-only repository permissions. It publishes neither a GitHub Release nor a container image.

## Immutable build inputs

The build rejects unexpected toolchain or packaging inputs. Current pins are:

- Ubuntu 26.04 image digest: `sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e`;
- Neutron catalogue release `30072026`, catalogue commit `08446d3f53116791558002ae19c61d41e4fb797a`, archive SHA-256 `aa1567215d2be42d0d054ae72627e6d18ef6ac80205847f1e7ce0db5736476f3`;
- Neutron LLVM commit `17efc66a340e35ae03a18e34e7f267832fff7940`;
- KernelSU-Next `v3.3.0`, commit `3b18216f71df189ab3d1b1ce0bdb21be1268e771`;
- SuSFS `v2.2.0`, commit `ab4c23cfc7cb26821abb7a9d2071206713c070fe`;
- AnyKernel3 commit `91e063d31dbe4b485ce00c26b1bf856696cba3c5`;
- Actions checkout `11bd71901bbe5b1630ceea73d27597364c9af683`, Buildx `e468171a9de216ec08956ac3ada2f0791b6bd435`, cache `5a3ec84eff668545956fd18022155c47e93e2684`, and artifact upload `ea165f8d65b6e75b540449e92b4886f43607fa02`.

The supplied reference release `[Vayu]-Anymore-20260809.zip` has SHA-256 `7EDC8637E4B76CE03F4C67426024EF71EA2C0DA1ABF353A9EE59423372664E3A`. It is an identity and layout reference only; none of its binaries are copied into a build.

## Package scope and device safety

This process creates the normal vayu/bhima package. For MIUI, use the normal package and the separately published `dtbo.img`. A distinct HyperOS/OxygenOS package is outside this build's scope; do not assume the normal package is interchangeable.

A successful compilation proves neither that the kernel boots nor that every device feature works. Back up the boot-critical partitions and user data, keep a known-good boot image and recovery path available, verify the device/ROM combination, and test booting and flashing on expendable hardware before daily use. Flashing a kernel can make a device unbootable or cause data loss.
