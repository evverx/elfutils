#!/bin/bash -eu

# This script is supposed to be compatible with OSS-Fuzz, i.e. it has to use
# environment variables like $CC, $CFLAGS and $OUT, link the fuzz targets with CXX
# (even though the project is written in C) and so on:
# https://google.github.io/oss-fuzz/getting-started/new-project-guide/#buildsh

# The fuzz targets it builds can't make any assumptions about
# their runtime environment apart from /tmp being writable:
# https://google.github.io/oss-fuzz/further-reading/fuzzer-environment/ .
# Even though it says there that it's possible to link fuzz targets against
# their dependencies dynamically by moving them to $OUT and changing
# rpath, it tends to break coverage reports from time to time https://github.com/google/oss-fuzz/issues/6524
# so all the dependencies are linked statically here.

# This script is configured via https://github.com/google/oss-fuzz/blob/master/projects/elfutils/project.yaml
# and used to build the elfutils project on OSS-Fuzz with three fuzzing engines
# (libFuzzer, AFL++ and honggfuzz) on two architectures (x86_64 and i386)
# with three sanitizers (ASan, UBSan and MSan) with coverage reports on top of
# all that: https://oss-fuzz.com/coverage-report/job/libfuzzer_asan_elfutils/latest
# so before changing anything ideally it should be tested with the OSS-Fuzz toolchain
# described at https://google.github.io/oss-fuzz/advanced-topics/reproducing/#building-using-docker
# by running something like:
#
# ./infra/helper.py pull_images
# ./infra/helper.py build_image --no-pull elfutils
# for sanitizer in address undefined memory; do
#   for engine in libfuzzer afl honggfuzz; do
#     ./infra/helper.py build_fuzzers --clean --sanitizer=$sanitizer --engine=$engine elfutils PATH/TO/ELFUTILS
#     ./infra/helper.py check_build --sanitizer=$sanitizer --engine=$engine -e ALLOWED_BROKEN_TARGETS_PERCENTAGE=0 elfutils
#   done
# done
#
# ./infra/helper.py build_fuzzers --clean --architecture=i386 elfutils PATH/TO/ELFUTILS
# ./infra/helper.py check_build --architecture=i386 -e ALLOWED_BROKEN_TARGETS_PERCENTAGE=0 elfutils
#
# ./infra/helper.py build_fuzzers --clean --sanitizer=coverage elfutils PATH/TO/ELFUTILS
# ./infra/helper.py coverage --no-corpus-download --fuzz-target=fuzz-dwfl-core --corpus-dir=PATH/TO/ELFUTILS/tests/fuzz-dwfl-core-crashes/ elfutils
#
# It should be possible to eventually automate that with ClusterFuzzLite https://google.github.io/clusterfuzzlite/
# but it doesn't seem to be compatible with buildbot currently.

# The script can also be used to build and run the fuzz target locally without Docker.
# After installing clang and the build dependencies of libelf by running something
# like `dnf build-dep elfutils-devel` on Fedora or `apt-get build-dep libelf-dev`
# on Debian/Ubuntu, the following commands should be run:
#
#  $ ./tests/build-fuzzers.sh
#  $ ./out/fuzz-dwfl-core tests/fuzz-dwfl-core-crashes/

set -eux

cd "$(dirname -- "$0")/.."

SANITIZER=${SANITIZER:-address}
flags="-O1 -fno-omit-frame-pointer -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -fsanitize=$SANITIZER -fsanitize=fuzzer-no-link"

export CC=${CC:-clang}
export CFLAGS=${CFLAGS:-$flags}

export CXX=${CXX:-clang++}
export CXXFLAGS=${CXXFLAGS:-$flags}

export OUT=${OUT:-"$(pwd)/out"}
mkdir -p "$OUT"

export LIB_FUZZING_ENGINE=${LIB_FUZZING_ENGINE:--fsanitize=fuzzer}

make clean || true

# ASan isn't compatible with -Wl,--no-undefined: https://github.com/google/sanitizers/issues/380
find -name Makefile.am | xargs sed -i 's/,--no-undefined//'

# ASan isn't compatible with -Wl,-z,defs either:
# https://clang.llvm.org/docs/AddressSanitizer.html#usage
sed -i 's/^\(ZDEFS_LDFLAGS=\).*/\1/' configure.ac

if [[ "$SANITIZER" == undefined ]]; then
    additional_ubsan_checks=alignment
    UBSAN_FLAGS="-fsanitize=$additional_ubsan_checks -fno-sanitize-recover=$additional_ubsan_checks"
    CFLAGS="$CFLAGS $UBSAN_FLAGS"
    CXXFLAGS="$CXXFLAGS $UBSAN_FLAGS"

    # That's basicaly what --enable-sanitize-undefined does to turn off unaligned access
    # elfutils heavily relies on on i386/x86_64 but without changing compiler flags along the way
    sed -i 's/\(check_undefined_val\)=[0-9]/\1=1/' configure.ac
fi

autoreconf -i -f
if ! ./configure --enable-maintainer-mode --disable-debuginfod --disable-libdebuginfod \
            --without-bzlib --without-lzma --without-zstd \
	    CC="$CC" CFLAGS="-Wno-error $CFLAGS" CXX="-Wno-error $CXX" CXXFLAGS="$CXXFLAGS" LDFLAGS="$CFLAGS"; then
    cat config.log
    exit 1
fi

ASAN_OPTIONS=detect_leaks=0 make -j$(nproc) V=1

# External dependencies used by the fuzz targets have to be built
# with MSan explictily to avoid bogus "security" bug reports like
# https://bugs.chromium.org/p/oss-fuzz/issues/detail?id=45630
# and https://bugs.chromium.org/p/oss-fuzz/issues/detail?id=45631.
zlib="-l:libz.a"
if [[ "$SANITIZER" == memory ]]; then
    (
    git clone https://github.com/madler/zlib
    cd zlib
    git checkout v1.2.11
    if ! ./configure --static; then
        cat configure.log
        exit 1
    fi
    make -j$(nproc) V=1
    )
    zlib=zlib/libz.a
fi

CFLAGS="$CFLAGS -Werror -Wall -Wextra"
CXXFLAGS="$CXXFLAGS -Werror -Wall -Wextra"

for f in tests/fuzz-*.c; do
    target=$(basename $f .c)
    [[ "$target" == "fuzz-main" ]] && continue
    $CC $CFLAGS \
      -D_GNU_SOURCE -DHAVE_CONFIG_H \
      -I. -I./lib -I./libelf -I./libebl -I./libdw -I./libdwelf -I./libdwfl -I./libasm \
      -c "$f" -o $target.o
    $CXX $CXXFLAGS $LIB_FUZZING_ENGINE $target.o \
      ./libdw/libdw.a ./libelf/libelf.a "$zlib" \
      -o "$OUT/$target"
    zip -r -j "$OUT/${target}_seed_corpus.zip" tests/${target}-crashes
done
