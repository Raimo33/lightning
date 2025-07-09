#TODO: try BASE_DISTRO=alpine:3.22
#TODO: separate build stages even more. for example build-bitcoin and build-litecoin

ARG DEFAULT_TARGETPLATFORM="linux/amd64"
ARG BASE_DISTRO="debian:bookworm-slim"

FROM --platform=$BUILDPLATFORM $BASE_DISTRO AS base-downloader

FROM base-downloader AS base-downloader-linux-amd64
ENV TARBALL_ARCH_FINAL=x86_64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm64
ENV TARBALL_ARCH_FINAL=aarch64-linux-gnu

FROM base-downloader AS base-downloader-linux-arm
ENV TARBALL_ARCH_FINAL=arm-linux-gnueabihf

FROM base-downloader-$TARGETOS-$TARGETARCH AS bitcoin-downloader

ARG BITCOIN_VERSION=27.1
ARG BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION
ARG BITCOIN_TARBALL=bitcoin-$BITCOIN_VERSION-$TARBALL_ARCH_FINAL.tar.gz

WORKDIR /opt/bitcoin

ADD $BITCOIN_URL/$BITCOIN_TARBALL  ./bitcoin.tar.gz
ADD $BITCOIN_URL/SHA256SUMS        ./SHA256SUMS
ADD $BITCOIN_URL/SHA256SUMS.asc    ./SHA256SUMS.asc
COPY gpg/bitcoin                   ./gpg/bitcoin

RUN gpg --import gpg/bitcoin/ && \
    gpg --verify SHA256SUMS.asc SHA256SUMS && \
    sha256sum -c SHA256SUMS --ignore-missing

RUN tar -xzf bitcoin.tar.gz --strip-components=1

ARG LITECOIN_VERSION=0.16.3
ARG LITECOIN_BASE_URL=https://download.litecoin.org/litecoin-$LITECOIN_VERSION
ARG LITECOIN_URL=$LITECOIN_BASE_URL/linux
ARG LITECOIN_TARBALL=litecoin-$LITECOIN_VERSION-$TARBALL_ARCH_FINAL.tar.gz

WORKDIR /opt/litecoin

ADD $LITECOIN_URL/$LITECOIN_TARBALL      ./litecoin.tar.gz
ADD $LITECOIN_URL/$LITECOIN_TARBALL.asc  ./litecoin.tar.gz.asc
ADD $LITECOIN_BASE_URL/SHA256SUMS.asc    ./SHA256SUMS.asc
COPY gpg/litecoin                        ./gpg/litecoin

RUN gpg --import gpg/litecoin && \
    gpg --verify SHA256SUMS.asc && \
    gpg --verify litecoin.tar.gz.asc litecoin.tar.gz && \
    sha256sum -c SHA256SUMS.asc --ignore-missing

FROM --platform=$DEFAULT_TARGETPLATFORM $BASE_DISTRO AS base-builder

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
ADD https://install.python-poetry.org                                                             ./install-poetry.py
ADD https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz                                            ./zlib.tar.gz
ADD https://www.sqlite.org/$SQLITE_YEAR/sqlite-src-$SQLITE_VERSION.zip                            ./sqlite.zip
ADD https://ftp.postgresql.org/pub/source/v$POSTGRES_VERSION/postgresql-$POSTGRES_VERSION.tar.gz  ./postgres.tar.gz

RUN python3 ./install-poetry.py && \
    poetry self add poetry-plugin-export

WORKDIR /opt/lightningd

COPY . .

RUN git submodule update --init --recursive

# Do not build python plugins (wss-proxy) here, python doesn't support cross compilation.
RUN sed -i '/^wss-proxy/d' pyproject.toml && \
    poetry lock && \
    poetry install --no-root --no-interaction --no-ansi

WORKDIR /

# FROM base-builder AS base-builder-linux-amd64

# ENV POSTGRES_CONFIG="--without-readline"
# ENV PG_CONFIG=/usr/local/pgsql/bin/pg_config

# FROM base-builder AS base-builder-linux-arm64

# ENV target_host=aarch64-linux-gnu \
#     target_host_rust=aarch64-unknown-linux-gnu \
#     target_host_qemu=qemu-aarch64-static

# RUN apt-get install -qq -y --no-install-recommends \
#         libc6-arm64-cross \
#         gcc-$target_host \
#         g++-$target_host

# ENV AR=$target_host-ar \
#     AS=$target_host-as \
#     CC=$target_host-gcc \
#     CXX=$target_host-g++ \
#     LD=$target_host-ld \
#     STRIP=$target_host-strip \
#     QEMU_LD_PREFIX=/usr/$target_host \
#     HOST=$target_host \
#     TARGET=$target_host_rust \
#     RUSTUP_INSTALL_OPTS="--target $target_host_rust --default-host $target_host_rust" \
#     PKG_CONFIG_PATH="/usr/$target_host/lib/pkgconfig"

# ENV ZLIB_CONFIG="--prefix=$QEMU_LD_PREFIX" \
#     SQLITE_CONFIG="--host=$target_host --prefix=$QEMU_LD_PREFIX" \
#     POSTGRES_CONFIG="--without-readline --prefix=$QEMU_LD_PREFIX" \
#     PG_CONFIG="$QEMU_LD_PREFIX/bin/pg_config"

# FROM base-builder AS base-builder-linux-arm

# ENV target_host=arm-linux-gnueabihf \
#     target_host_rust=armv7-unknown-linux-gnueabihf \
#     target_host_qemu=qemu-arm-static

# RUN apt-get install -qq -y --no-install-recommends \
#         libc6-armhf-cross \
#         gcc-$target_host \
#         g++-$target_host

# ENV AR=$target_host-ar \
#     AS=$target_host-as \
#     CC=$target_host-gcc \
#     CXX=$target_host-g++ \
#     LD=$target_host-ld \
#     STRIP=$target_host-strip \
#     QEMU_LD_PREFIX=/usr/$target_host \
#     HOST=$target_host \
#     TARGET=$target_host_rust \
#     RUSTUP_INSTALL_OPTS="--target $target_host_rust --default-host $target_host_rust" \
#     PKG_CONFIG_PATH="/usr/$target_host/lib/pkgconfig"

# ENV ZLIB_CONFIG="--prefix=$QEMU_LD_PREFIX" \
#     SQLITE_CONFIG="--host=$target_host --prefix=$QEMU_LD_PREFIX" \
#     POSTGRES_CONFIG="--without-readline --prefix=$QEMU_LD_PREFIX" \
#     PG_CONFIG="$QEMU_LD_PREFIX/bin/pg_config"

# FROM base-builder-$TARGETOS-$TARGETARCH AS builder

# ENV LIGHTNINGD_VERSION=master

# RUN mkdir zlib && tar xvf zlib.tar.gz -C zlib --strip-components=1 \
#     && cd zlib \
#     && ./configure $ZLIB_CONFIG \
#     && make \
#     && make install && cd .. && \
#     rm zlib.tar.gz && \
#     rm -rf zlib

# RUN unzip sqlite.zip \
#     && cd sqlite-* \
#     && ./configure --enable-static --disable-readline --disable-threadsafe --disable-load-extension $SQLITE_CONFIG \
#     && make \
#     && make install && cd .. && rm sqlite.zip && rm -rf sqlite-*

# RUN mkdir postgres && tar xvf postgres.tar.gz -C postgres --strip-components=1 \
#     && cd postgres \
#     && ./configure $POSTGRES_CONFIG \
#     && cd src/include \
#     && make install \
#     && cd ../interfaces/libpq \
#     && make install \
#     && cd ../../bin/pg_config \
#     && make install \
#     && cd ../../../../ && \
#     rm postgres.tar.gz && \
#     rm -rf postgres && \
#     ldconfig "$($PG_CONFIG --libdir)"

# # Save libpq to a specific location to copy it into the final image.
# RUN mkdir /var/libpq && cp -a "$($PG_CONFIG --libdir)"/libpq.* /var/libpq

# ENV RUST_PROFILE=release \
#     PATH="/root/.cargo/bin:/root/.local/bin:$PATH"
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y $RUSTUP_INSTALL_OPTS
# RUN rustup toolchain install stable --component rustfmt --allow-downgrade

# COPY --from=downloader /usr/bin/$target_host_qemu /usr/bin/$target_host_qemu
# WORKDIR /opt/lightningd

# # If cross-compiling, need to tell it to cargo.
# RUN ( ! [ -n "$target_host" ] ) || \
#     (mkdir -p .cargo && echo "[target.$target_host_rust]\nlinker = \"$target_host-gcc\"" > .cargo/config)

# # Weird errors with cargo for cln-grpc on arm7 https://github.com/ElementsProject/lightning/issues/6596
# RUN ( ! [ "$target_host" = "arm-linux-gnueabihf" ] ) || \
#     (sed -i '/documentation = "https:\/\/docs.rs\/cln-grpc"/a include = ["**\/*.*"]' cln-grpc/Cargo.toml)

# # Ensure that the desired grpcio-tools & protobuf versions are installed
# # https://github.com/ElementsProject/lightning/pull/7376#issuecomment-2161102381
# RUN poetry lock && poetry install && \
#     poetry self add poetry-plugin-export

# # Ensure that git differences are removed before making bineries, to avoid `-modded` suffix
# # poetry.lock changed due to pyln-client, pyln-proto and pyln-testing version updates
# # pyproject.toml was updated to exclude wss-proxy plugins in base-builder stage
# RUN git reset --hard HEAD

# RUN ./configure --prefix=/tmp/lightning_install --enable-static && poetry run make install

# # Export the requirements for the plugins so we can install them in builder-python stage
# WORKDIR /opt/lightningd/plugins/wss-proxy
# RUN poetry lock && poetry export -o requirements.txt --without-hashes
# WORKDIR /opt/lightningd
# RUN echo 'RUSTUP_INSTALL_OPTS="$RUSTUP_INSTALL_OPTS"' > /tmp/rustup_install_opts.txt

# # We need to build python plugins on the target's arch because python doesn't support cross build
# FROM $BASE_DISTRO AS builder-python
# RUN apt-get update -qq && \
#     apt-get install -qq -y --no-install-recommends \
#         git \
#         curl \
#         libtool \
#         pkg-config \
#         autoconf \
#         automake \
#         build-essential \
#         libffi-dev \
#         libssl-dev \
#         python3 \
#         python3-dev \
#         python3-pip \
#         python3-venv && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*

# ENV PYTHON_VERSION=3
# RUN mkdir -p /root/.venvs && \
#     python3 -m venv /root/.venvs/cln && \
#     . /root/.venvs/cln/bin/activate && \
#     pip3 install --upgrade pip setuptools wheel

# # Copy rustup_install_opts.txt file from builder
# COPY --from=builder /tmp/rustup_install_opts.txt /tmp/rustup_install_opts.txt
# # Setup ENV $RUSTUP_INSTALL_OPTS for this stage
# RUN export $(cat /tmp/rustup_install_opts.txt)
# ENV PATH="/root/.cargo/bin:/root/.venvs/cln/bin:$PATH"
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y $RUSTUP_INSTALL_OPTS

# WORKDIR /opt/lightningd/plugins/wss-proxy
# COPY --from=builder /opt/lightningd/plugins/wss-proxy/requirements.txt .
# RUN pip3 install -r requirements.txt
# RUN pip3 cache purge

# WORKDIR /opt/lightningd

# FROM $BASE_DISTRO AS final

# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#       tini \
#       socat \
#       inotify-tools \
#       jq \
#       python3 \
#       python3-pip && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*

# ENV LIGHTNINGD_DATA=/root/.lightning \
#     LIGHTNINGD_RPC_PORT=9835 \
#     LIGHTNINGD_PORT=9735 \
#     LIGHTNINGD_NETWORK=bitcoin

# RUN mkdir $LIGHTNINGD_DATA && \
#     touch $LIGHTNINGD_DATA/config
# VOLUME [ "/root/.lightning" ]

# # Take libpq directly from builder.
# RUN mkdir /var/libpq && mkdir -p /usr/local/pgsql/lib
# RUN --mount=type=bind,from=builder,source=/var/libpq,target=/var/libpq,rw \
#     cp -a /var/libpq/libpq.* /usr/local/pgsql/lib && \
#     echo "/usr/local/pgsql/lib" > /etc/ld.so.conf.d/libpq.conf && \
#     ldconfig

# COPY --from=builder /tmp/lightning_install/ /usr/local/
# COPY --from=builder-python /root/.venvs/cln/lib/python3.11/site-packages /usr/local/lib/python3.11/dist-packages/
# COPY --from=downloader /opt/bitcoin/bin /usr/bin
# COPY --from=downloader /opt/litecoin/bin /usr/bin
# COPY tools/docker-entrypoint.sh entrypoint.sh

# EXPOSE 9735 9835
# ENTRYPOINT  ["./entrypoint.sh" ]
