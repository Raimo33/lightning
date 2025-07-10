#TODO: try BASE_DISTRO=alpine:3.22
#TODO: strip binaries

ARG BASE_DISTRO="debian:bookworm-slim"

FROM $BASE_DISTRO AS base-downloader

FROM base-downloader AS base-downloader-linux-amd64
ENV TARBALL_ARCH_FINAL=x86_64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm64
ENV TARBALL_ARCH_FINAL=aarch64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm
ENV TARBALL_ARCH_FINAL=arm-linux-gnueabihf

FROM base-downloader-$TARGETOS-$TARGETARCH AS downloader

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends \
        gnupg

ARG BITCOIN_VERSION=27.1
ARG BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION
ARG BITCOIN_TARBALL=bitcoin-$BITCOIN_VERSION-$TARBALL_ARCH_FINAL.tar.gz

WORKDIR /opt/bitcoin

ADD $BITCOIN_URL/$BITCOIN_TARBALL  .
ADD $BITCOIN_URL/SHA256SUMS        .
ADD $BITCOIN_URL/SHA256SUMS.asc    .
COPY gpg/bitcoin/                  gpg/

RUN gpg --import gpg/* && \
    gpg --verify SHA256SUMS.asc SHA256SUMS && \
    sha256sum -c SHA256SUMS --ignore-missing

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

RUN gpg --import gpg/* && \
    gpg --verify SHA256SUMS.asc && \
    gpg --verify $LITECOIN_TARBALL.asc $LITECOIN_TARBALL && \
    sha256sum -c SHA256SUMS.asc --ignore-missing

RUN tar xvf $LITECOIN_TARBALL --strip-components=1

WORKDIR /opt

FROM $BASE_DISTRO AS base-builder

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends \
        ca-certificates \
        python3 \
        git

ARG PYTHON_VERSION=3
ARG POETRY_VERSION=2.0.1
ARG ZLIB_VERSION=1.2.13
ARG SQLITE_YEAR=2019
ARG SQLITE_VERSION=3290000
ARG POSTGRES_VERSION=17.1
ARG POETRY_HOME=/usr/bin

#TODO verify GPG
ADD https://sh.rustup.rs                                                                          /opt/install-rust.sh
ADD https://install.python-poetry.org                                                             /opt/install-poetry.py
ADD https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz                                            /opt/zlib.tar.gz
ADD https://www.sqlite.org/$SQLITE_YEAR/sqlite-src-$SQLITE_VERSION.zip                            /opt/sqlite.zip
ADD https://ftp.postgresql.org/pub/source/v$POSTGRES_VERSION/postgresql-$POSTGRES_VERSION.tar.gz  /opt/postgres.tar.gz

WORKDIR /opt/lightningd

COPY . .

RUN git submodule update --init --recursive

WORKDIR /opt

FROM base-builder AS base-builder-linux-amd64

ENV target_host=x86_64-linux-gnu
ENV target_host_rust=x86_64-unknown-linux-gnu
ENV target_host_qemu=qemu-x86_64-static

FROM base-builder AS base-builder-linux-arm64

ENV target_host=aarch64-linux-gnu
ENV target_host_rust=aarch64-unknown-linux-gnu
ENV target_host_qemu=qemu-aarch64-static

FROM base-builder AS base-builder-linux-arm

ENV target_host=arm-linux-gnueabihf
ENV target_host_rust=armv7-unknown-linux-gnueabihf
ENV target_host_qemu=qemu-arm-static

FROM base-builder-$TARGETOS-$TARGETARCH AS builder

#TODO: check all possible configure options and remove unnecessary ones

WORKDIR /opt/zlib

RUN tar xvf /opt/zlib.tar.gz --strip-components=1
RUN ./configure --prefix=/usr/$target_host
RUN make -j
RUN make install

WORKDIR /opt/sqlite

RUN tar xvf /opt/sqlite.zip --strip-components=1
RUN ./configure --host=$target_host --prefix=/usr/$target_host --enable-static --disable-readline --disable-threadsafe --disable-load-extension
RUN make -j
RUN make install

WORKDIR /opt/postgres

RUN tar xvf /opt/postgres.tar.gz --strip-components=1
RUN ./configure --prefix=/usr/$target_host --without-readline
RUN make install -C src/include
RUN make install -C interfaces/libpq
RUN make install -C bin/pg_config
RUN ldconfig "$(/usr/$target_host/bin/pg_config --libdir)"

RUN ./opt/install-rust.sh -y --target $target_host_rust --default-host $target_host_rust
RUN rustup toolchain install stable --component rustfmt --allow-downgrade

WORKDIR /opt/lightningd

RUN cat <<EOF > .cargo/config
  [target.$target_host_rust]
  linker = "$target_host-gcc"
EOF

# Weird errors with cargo for cln-grpc on arm7 https://github.com/ElementsProject/lightning/issues/6596
RUN if [ "$target_host" = "arm-linux-gnueabihf" ]; then \
  sed -i '/documentation = "https:\/\/docs.rs\/cln-grpc"/a include = ["**\/*.*"]' cln-grpc/Cargo.toml; \
fi

RUN python3 /opt/install-poetry.py && \
    poetry self add poetry-plugin-export && \
    poetry lock && \
    poetry install --no-root --no-interaction --no-ansi --no-dev

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

VOLUME [ "/root/.lightning" ]

COPY --from=builder     /tmp/lightning_install/     /usr/local/
COPY --from=downloader  /opt/bitcoin/bin            /usr/bin
COPY --from=downloader  /opt/litecoin/bin           /usr/bin
COPY tools/docker-entrypoint.sh                     /entrypoint.sh

EXPOSE 9735 9835
ENTRYPOINT  ["./entrypoint.sh" ]
#TODO refactor entrypoint