# syntax=docker/dockerfile:1
# Ubuntu 26.04 supplies glibc 2.43 required by the pinned Neutron archive.
FROM ubuntu:26.04@sha256:b7f48194d4d8b763a478a621cdc81c27be222ba2206ca3ca6bc42b49685f3d9e

ARG BUILDER_UID=1000
ARG BUILDER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive \
    CLANG_DIR=/opt/neutron-clang \
    CCACHE_DIR=/ccache \
    HOME=/home/builder \
    PATH=/opt/neutron-clang/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash bc bison build-essential ca-certificates ccache cpio curl file flex gawk \
      gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi git libelf-dev libncurses-dev \
      libssl-dev lz4 make perl python3 rsync unzip xz-utils zip zstd \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build-versions.env /tmp/build-versions.env
RUN set -eux; \
    . /tmp/build-versions.env; \
    curl --fail --location --retry 3 \
      "https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/30072026/neutron-clang-30072026.tar.zst" \
      --output /tmp/neutron-clang.tar.zst; \
    printf '%s  %s\n' "$NEUTRON_ARCHIVE_SHA256" /tmp/neutron-clang.tar.zst | sha256sum -c -; \
    mkdir -p "$CLANG_DIR"; \
    tar --use-compress-program=unzstd --extract --file /tmp/neutron-clang.tar.zst \
      --strip-components=1 --directory "$CLANG_DIR"; \
    rm /tmp/neutron-clang.tar.zst /tmp/build-versions.env; \
    clang --version; \
    "$CLANG_DIR/bin/clang" --version | grep -F 'Neutron clang version 24.0.0git'; \
    "$CLANG_DIR/bin/clang" --version | grep -F "$NEUTRON_LLVM_COMMIT"; \
    ld.lld --version; \
    "$CLANG_DIR/bin/ld.lld" --version | grep -F 'Neutron LLD version 24.0.0git'; \
    "$CLANG_DIR/bin/ld.lld" --version | grep -F "$NEUTRON_LLVM_COMMIT"

RUN groupadd --gid "$BUILDER_GID" builder \
    && useradd --uid "$BUILDER_UID" --gid "$BUILDER_GID" --create-home --shell /bin/bash builder \
    && mkdir -p /workspace "$CCACHE_DIR" \
    && chown -R builder:builder /workspace "$CCACHE_DIR"

WORKDIR /workspace
USER builder
CMD ["./build.sh"]
