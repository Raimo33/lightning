#TODO: try BASE_DISTRO=alpine:3.22
#TODO: strip binaries

ARG BASE_DISTRO="debian:bookworm-slim"

FROM $BASE_DISTRO AS base-downloader

FROM base-downloader AS base-downloader-linux-amd64
ARG TARBALL_ARCH_FINAL=x86_64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm64
ARG TARBALL_ARCH_FINAL=aarch64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm
ARG TARBALL_ARCH_FINAL=arm-linux-gnueabihf

FROM base-downloader-$TARGETOS-$TARGETARCH AS downloader

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends
        # gnupg

ARG BITCOIN_VERSION=27.1
ARG BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION
ARG BITCOIN_TARBALL=bitcoin-$BITCOIN_VERSION-$TARBALL_ARCH_FINAL.tar.gz

WORKDIR /opt/bitcoin

ADD $BITCOIN_URL/$BITCOIN_TARBALL  .
ADD $BITCOIN_URL/SHA256SUMS        .
ADD $BITCOIN_URL/SHA256SUMS.asc    .
COPY gpg/bitcoin/                  gpg/

#TODO verify GPG
# RUN gpg --import gpg/* && \
#     gpg --verify SHA256SUMS.asc SHA256SUMS && \
#     sha256sum -c SHA256SUMS --ignore-missing

RUN tar xvf $BITCOIN_TARBALL --strip-components=1

ARG LITECOIN_VERSION=0.16.3
ARG LITECOIN_BASE_URL=https://download.litecoin.org/litecoin-$LITECOIN_VERSION
ARG LITECOIN_URL=$LITECOIN_BASE_URL/linux
ARG LITECOIN_TARBALL=litecoin-$LITECOIN_VERSION-$TARBALL_ARCH_FINAL.tar.gz

WORKDIR /opt/litecoin

ADD $LITECOIN_URL/$LITECOIN_TARBALL      .
ADD $LITECOIN_URL/$LITECOIN_TARBALL.asc  .
ADD $LITECOIN_BASE_URL/SHA256SUMS.asc    .
COPY gpg/litecoin/                       gpg/

#TODO verify GPG
# RUN gpg --import gpg/* && \
#     gpg --verify SHA256SUMS.asc && \
#     gpg --verify $LITECOIN_TARBALL.asc $LITECOIN_TARBALL && \
#     sha256sum -c SHA256SUMS.asc --ignore-missing

RUN tar xvf $LITECOIN_TARBALL --strip-components=1

WORKDIR /opt

FROM $BASE_DISTRO AS base-builder

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends \
        ca-certificates \
        python3 \
        git \
        automake \
        build-essential \
        pkg-config \
        libicu-dev \
        bison \
        flex \
        wget \
        jq \
        qemu-user-static

ARG ZLIB_VERSION=1.2.13
ARG SQLITE_YEAR=2019
ARG SQLITE_VERSION=3290000
ARG POSTGRES_VERSION=17.1

#TODO verify GPG
ADD --chmod=750 https://sh.rustup.rs                                                              /opt/install-rust.sh
ADD --chmod=750 https://install.python-poetry.org                                                 /opt/install-poetry.py
ADD https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz                                            /opt/zlib.tar.gz
ADD https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz                    /opt/sqlite.tar.gz
ADD https://ftp.postgresql.org/pub/source/v$POSTGRES_VERSION/postgresql-$POSTGRES_VERSION.tar.gz  /opt/postgres.tar.gz

WORKDIR /opt/lightningd

COPY . .

RUN git submodule update --init --recursive

WORKDIR /opt

FROM base-builder AS base-builder-linux-amd64

ARG target_host=x86_64-linux-gnu
ARG target_host_rust=x86_64-unknown-linux-gnu

FROM base-builder AS base-builder-linux-arm64

ARG target_host=aarch64-linux-gnu
ARG target_host_rust=aarch64-unknown-linux-gnu

FROM base-builder AS base-builder-linux-arm

ARG target_host=arm-linux-gnueabihf
ARG target_host_rust=armv7-unknown-linux-gnueabihf

FROM base-builder-$TARGETOS-$TARGETARCH AS builder

ENV RUST_PROFILE=release
ENV LIGHTNINGD_VERSION=master

ARG AR=$target_host-ar
ARG AS=$target_host-as
ARG CC=$target_host-gcc
ARG CXX=$target_host-g++
ARG LD=$target_host-ld
ARG STRIP=$target_host-strip
ARG QEMU_LD_PREFIX=/usr/$target_host
ARG TARGET=$target_host_rust
ARG PKG_CONFIG_PATH=/usr/$target_host/lib/pkgconfig

WORKDIR /opt

RUN ./install-rust.sh -y --target $target_host_rust --default-host $target_host_rust
RUN ./install-poetry.py

ENV PATH="/root/.cargo/bin:/root/.local/bin:$PATH"

RUN rustup toolchain install stable --component rustfmt --allow-downgrade
RUN poetry self add poetry-plugin-export

WORKDIR /opt/zlib

#TODO: check all possible configure options and remove unnecessary ones
RUN tar xvf /opt/zlib.tar.gz --strip-components=1
RUN ./configure --prefix=$QEMU_LD_PREFIX
RUN make -j
RUN make install

WORKDIR /opt/sqlite

#TODO: check all possible configure options and remove unnecessary ones
RUN tar xvf /opt/sqlite.tar.gz --strip-components=1
RUN ./configure --host=$target_host --prefix=$QEMU_LD_PREFIX --enable-static --disable-readline --disable-threadsafe --disable-load-extension
RUN make -j
RUN make install

WORKDIR /opt/postgres

#TODO: check all possible configure options and remove unnecessary ones
RUN tar xvf /opt/postgres.tar.gz --strip-components=1
RUN ./configure --prefix=$QEMU_LD_PREFIX --without-readline
RUN make install -C src/include
RUN make install -C src/interfaces/libpq
RUN make install -C src/bin/pg_config
RUN ldconfig "$($QEMU_LD_PREFIX/bin/pg_config --libdir)"

WORKDIR /opt/lightningd

RUN mkdir -p .cargo && tee .cargo/config <<-EOF
  [target.$target_host_rust]
  linker = "$target_host-gcc"
EOF

RUN poetry lock && \
    poetry install --no-root --no-interaction --no-ansi

RUN ./configure --prefix=/tmp/lightning_install --enable-static
RUN poetry run make install

FROM $BASE_DISTRO AS final

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends \
        libpq5

ENV LIGHTNINGD_DATA=/root/.lightning
ENV LIGHTNINGD_RPC_PORT=9835
ENV LIGHTNINGD_PORT=9735
ENV LIGHTNINGD_NETWORK=bitcoin

VOLUME ["/root/.lightning"]

COPY --from=builder     /tmp/lightning_install/    /usr/local/
COPY --from=downloader  /opt/bitcoin/bin           /usr/bin
COPY --from=downloader  /opt/litecoin/bin          /usr/bin
COPY tools/docker-entrypoint.sh                    /entrypoint.sh

EXPOSE 9735 9835
ENTRYPOINT  ["/entrypoint.sh"]
#TODO refactor entrypoint