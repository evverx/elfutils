#!/bin/bash

# shellcheck disable=SC2206
PHASES=(${@:-SETUP RUN_GCC})
RELEASE="$(lsb_release -cs)"
ADDITIONAL_DEPS=(
    clang
    libcurl4-gnutls-dev
    libmicrohttpd-dev
    libsqlite3-dev
    libarchive-dev
    libzstd-dev
    valgrind
)

set -ex

for phase in "${PHASES[@]}"; do
    case $phase in
        SETUP)
            bash -c "echo 'deb-src http://archive.ubuntu.com/ubuntu/ $RELEASE main restricted universe multiverse' >>/etc/apt/sources.list"
            apt-get -y update
            apt-get build-dep -y --no-install-recommends elfutils
            apt-get -y install "${ADDITIONAL_DEPS[@]}"
            ;;
        RUN_GCC|RUN_CLANG)
            export CC=gcc
            export CXX=g++
            if [[ "$phase" = "RUN_CLANG" ]]; then
                export CC=clang
                export CXX=clang++
                # elfutils is failing to compile with clang with -Werror
                # https://sourceware.org/pipermail/elfutils-devel/2021q1/003538.html
                # https://reviews.llvm.org/D97445
                export CFLAGS="-Wno-xor-used-as-pow -Wno-gnu-variable-sized-type-not-at-end"
                export CXXFLAGS="-Wno-xor-used-as-pow -Wno-gnu-variable-sized-type-not-at-end"
            fi

            $CC --version
            autoreconf -i -f
            ./configure --enable-maintainer-mode
            make -j$(nproc) V=1
            if ! make V=1 check; then
                cat tests/test-suite.log
                exit 1
            fi
            make V=1 distcheck
            ;;
        *)
            echo >&2 "Unknown phase '$phase'"
            exit 1
    esac
done
