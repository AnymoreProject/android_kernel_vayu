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

### KernelSU‑Next / SusFS integration
The committed `vayu_defconfig` sets `CONFIG_KSU=y` / `CONFIG_SUSFS=y`, but those Kconfig symbols and the
driver/SusFS sources are **not in the tree** — they are fetched at CI time (see `.github/workflows/main2.yml`):
clone `https://github.com/sidex15/KernelSU-Next` (branch `legacy-susfs-v2`) and copy its `kernel/*` into the
tree (`obj-y += KernelSU/` in `drivers/Makefile`). Because the Kconfig symbols are absent in the committed
tree, the `#ifdef CONFIG_SUSFS` blocks compile out by default, but `fs/open.c`, `fs/stat.c`,
`fs/proc_namespace.c` and `security/selinux/ss/services.c` still `#include <linux/susfs.h>` **unconditionally**,
so that header must exist for those files to compile.

### Known pre-existing source bug (NOT an environment issue)
`fs/open.c` has a duplicated `long do_sys_open(...)` definition line (the SusFS patch commit introduced it),
which is a hard syntax error. A clean full build to `Image` is blocked on this committed code bug; the
cross‑compile environment itself is healthy and compiles the rest of the tree. Do not "fix" it unless asked.

### No automated tests / lint
There is no unit‑test suite or repo lint config. Validation == the kernel compiles. CI lives in
`.github/workflows/main.yml` and `main2.yml` (manual `workflow_dispatch` arm64 builds).
