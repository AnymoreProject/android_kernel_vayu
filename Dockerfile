# syntax=docker/dockerfile:1
# Ubuntu 26.04 supplies glibc 2.43 required by the pinned Neutron archive.
FROM ubuntu:26.04@sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e

ARG BUILDER_UID=1000
ARG BUILDER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive \
    CLANG_DIR=/opt/neutron-clang \
    ANYKERNEL_DIR=/opt/AnyKernel3 \
    CCACHE_DIR=/ccache \
    HOME=/home/builder \
    PATH=/opt/neutron-clang/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash bc bison build-essential ca-certificates ccache cpio curl file flex gawk \
      gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi git libelf-dev libncurses-dev \
      libssl-dev lz4 make perl python3 rsync unzip xz-utils zip zstd \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build-versions.env scripts/anykernel-overlay/anykernel.sh /tmp/
RUN set -eux; \
    . /tmp/build-versions.env; \
    case "$NEUTRON_ARCHIVE_URL" in \
      "https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/$NEUTRON_CATALOGUE_RELEASE/neutron-clang-$NEUTRON_CATALOGUE_RELEASE.tar.zst") ;; \
      *) printf 'unexpected Neutron archive URL: %s\n' "$NEUTRON_ARCHIVE_URL" >&2; exit 1 ;; \
    esac; \
    curl --fail --location --retry 3 "$NEUTRON_CATALOGUE_MANIFEST_URL" --output /tmp/neutron-manifest; \
    grep -Fqx -- "$NEUTRON_ARCHIVE_SHA256" /tmp/neutron-manifest; \
    curl --fail --location --retry 3 "$NEUTRON_ARCHIVE_URL" --output /tmp/neutron-clang.tar.zst; \
    printf '%s  %s\n' "$NEUTRON_ARCHIVE_SHA256" /tmp/neutron-clang.tar.zst | sha256sum -c -; \
    mkdir -p "$CLANG_DIR"; \
    tar --use-compress-program=unzstd --extract --file /tmp/neutron-clang.tar.zst \
      --strip-components=1 --directory "$CLANG_DIR"; \
    rm /tmp/neutron-clang.tar.zst /tmp/neutron-manifest; \
    clang --version; \
    "$CLANG_DIR/bin/clang" --version | grep -F 'Neutron clang version 24.0.0git'; \
    "$CLANG_DIR/bin/clang" --version | grep -F "$NEUTRON_LLVM_COMMIT"; \
    ld.lld --version; \
    "$CLANG_DIR/bin/ld.lld" --version | grep -F 'Neutron LLD 24.0.0 ('; \
    "$CLANG_DIR/bin/ld.lld" --version | grep -F "$NEUTRON_LLVM_COMMIT"; \
    git init "$ANYKERNEL_DIR"; \
    git -C "$ANYKERNEL_DIR" remote add origin "$ANYKERNEL3_REPOSITORY"; \
    git -C "$ANYKERNEL_DIR" fetch --depth 1 origin "$ANYKERNEL3_REF"; \
    test "$(git -C "$ANYKERNEL_DIR" rev-parse FETCH_HEAD)" = "$ANYKERNEL3_COMMIT"; \
    git -C "$ANYKERNEL_DIR" checkout --detach "$ANYKERNEL3_COMMIT"; \
    git -C "$ANYKERNEL_DIR" reset --hard "$ANYKERNEL3_COMMIT"; \
    git -C "$ANYKERNEL_DIR" clean -ffdqx; \
    install -m 0644 /tmp/anykernel.sh "$ANYKERNEL_DIR/anykernel.sh"; \
    grep -Fqx -- "device.name1=vayu" "$ANYKERNEL_DIR/anykernel.sh"; \
    grep -Fqx -- "device.name2=bhima" "$ANYKERNEL_DIR/anykernel.sh"; \
    grep -Fqx -- "supported.versions=11 - 17" "$ANYKERNEL_DIR/anykernel.sh"; \
    grep -Fqx -- "kernel.string=KyriePatch" "$ANYKERNEL_DIR/anykernel.sh"; \
    git -C "$ANYKERNEL_DIR" update-index --assume-unchanged anykernel.sh; \
    test -z "$(git -C "$ANYKERNEL_DIR" status --porcelain)"; \
    rm /tmp/build-versions.env /tmp/anykernel.sh

RUN groupadd --gid "$BUILDER_GID" builder \
    && useradd --uid "$BUILDER_UID" --gid "$BUILDER_GID" --create-home --shell /bin/bash builder \
    && mkdir -p /workspace "$CCACHE_DIR" \
    && chown -R builder:builder /workspace "$CCACHE_DIR" "$ANYKERNEL_DIR"

WORKDIR /workspace
USER builder
CMD ["./build.sh"]
