# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
This is the **Anymore Kernel for Xiaomi POCO X3 Pro / vayu** — an Android **Linux 4.14.357** arm64
kernel source tree (Qualcomm `sm8150`) with KernelSU‑Next + SusFS patches. The "application" is the
kernel itself; "running it" means **cross‑compiling it for arm64**. There is no service to start.

### Toolchain & deps (already installed by the update script)
- arm64 builds use the **crDroid AOSP clang** toolchain at `/root/clang` (clang `r547379`, ver 20.x),
  the same toolchain referenced by `build.sh`. Put it on `PATH` before building:
  `export PATH="/root/clang/bin:$PATH"`.
- System packages used by the build: `bc bison flex libssl-dev libelf-dev lld llvm clang ccache zip kmod cpio`.
- The host clang (`/usr/bin/clang` 18.x) is fine for `HOSTCC`; the AOSP clang handles the arm64 target.

### Build / generate config (the core dev workflow)
Defconfig is `vayu_defconfig`. Generate config + build out‑of‑tree into `out/`:
```
export PATH="/root/clang/bin:$PATH"
make -s O=out ARCH=arm64 vayu_defconfig
make -j"$(nproc)" O=out ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
  LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy \
  OBJDUMP=llvm-objdump READELF=llvm-readelf HOSTCC=clang HOSTCXX=clang++ \
  HOSTAR=llvm-ar HOSTLD=ld.lld LLVM=1 LLVM_IAS=1 CC="ccache clang"
```
**Gotcha:** you MUST pass `CROSS_COMPILE=aarch64-linux-gnu-` (or `CLANG_TRIPLE`). Without it, clang
defaults to the x86 host target and fails with `unknown target CPU 'armv8.2-a+...'`. `LLVM=1` means the
GNU `aarch64-linux-gnu-*` binaries do not need to exist; the prefix only selects the clang `--target`.

The successful artifact is `out/arch/arm64/boot/Image` (+ `dtbo.img`, `dtb.img`). `build.sh` wraps the
above and then copies the image into an AnyKernel3 flashable zip (`/root/AnyKernel3`, not present in CI).

### KernelSU‑Next / SuSFS / KPROBES integration (branch `cursor/ksunext-susfs-kprobes-*`)
This branch ships a real, building integration:
- **KernelSU‑Next** is a git submodule at `KernelSU-Next/` (`sidex15/KernelSU-Next`, branch
  `next-susfs_v1.5.5-v1.5.7`), wired via the `drivers/kernelsu` symlink + `obj-$(CONFIG_KSU)` in
  `drivers/Makefile` and `source "drivers/kernelsu/Kconfig"` in `drivers/Kconfig`.
  **You must run `git submodule update --init --recursive`** after checkout or the build fails.
- **SuSFS** = `simonpunk/susfs4ksu` `kernel-4.14` (v1.5.5): the `50_add_susfs_in_kernel-4.14.patch` is
  already applied to the tree, and `fs/susfs.c` / `include/linux/susfs*.h` are committed.
- **Hooks**: KSU uses kprobe hooks (`CONFIG_KSU_KPROBES_HOOK=y`, needs `CONFIG_KPROBES=y`). The optional
  `SUS_SU` runtime toggle needs `CONFIG_KPROBE_EVENTS`/`FTRACE`, which are intentionally left off (perf).
- `vayu_defconfig` enables `CONFIG_KSU`, `CONFIG_KSU_KPROBES_HOOK` and the full `CONFIG_KSU_SUSFS*` set.

**Build gotcha (determinism):** KernelSU‑Next's `kernel/Makefile` injects `path_umount`/`can_umount` into
`fs/namespace.c`+`fs/internal.h` and `get_cred_rcu` into `include/linux/cred.h` via `sed` *during* the build.
On a fresh tree the object is compiled before the injection → first build fails with
`undefined symbol: path_umount`. These backports are now **pre-committed** to the source so the Makefile's
grep-guards skip injection and clean builds succeed first-try. Do not revert them.

### Flashable package
CI (`.github/workflows/main*.yml`) packs the kernel into an `osm0sis/AnyKernel3` recovery zip
(`device.name1=vayu`, `device.name2=bhima`, `BLOCK=/dev/block/bootdevice/by-name/boot`), bundling
`out/arch/arm64/boot/Image`, `dtb.img` (as `dtb`) and `dtbo.img`.

### No automated tests / lint
There is no unit‑test suite or repo lint config. Validation == the kernel compiles. CI lives in
`.github/workflows/main.yml` and `main2.yml` (manual `workflow_dispatch` arm64 builds).
