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
    lcov
)
COVERITY_SCAN_TOOL_BASE="/tmp/coverity-scan-analysis"
COVERITY_SCAN_PROJECT_NAME="evverx/elfutils"

CLANG_NO_ERROR_FLAGS=()

set -ex

function coverity_install_script {
    set +x # This is supposed to hide COVERITY_SCAN_TOKEN
    local platform=$(uname)
    local tool_url="https://scan.coverity.com/download/${platform}"
    local tool_archive="/tmp/cov-analysis-${platform}.tgz"

    echo -e "\033[33;1mDownloading Coverity Scan Analysis Tool...\033[0m"
    wget -nv -O $tool_archive $tool_url --post-data "project=$COVERITY_SCAN_PROJECT_NAME&token=$COVERITY_SCAN_TOKEN" || return

    echo -e "\033[33;1mExtracting Coverity Scan Analysis Tool...\033[0m"
    mkdir -p $COVERITY_SCAN_TOOL_BASE
    pushd $COVERITY_SCAN_TOOL_BASE
    tar xzf $tool_archive || return
    popd
    set -x
}

function run_coverity {
    set +x # This is supposed to hide COVERITY_SCAN_TOKEN
    local results_dir="cov-int"
    local tool_dir=$(find $COVERITY_SCAN_TOOL_BASE -type d -name 'cov-analysis*')
    local results_archive="analysis-results.tgz"
    local sha=$(git rev-parse --short HEAD)
    local response status_code

    echo -e "\033[33;1mRunning Coverity Scan Analysis Tool...\033[0m"
    COVERITY_UNSUPPORTED=1 $tool_dir/bin/cov-build --dir $results_dir sh -c "make -j V=1" || return
    $tool_dir/bin/cov-import-scm --dir $results_dir --scm git --log $results_dir/scm_log.txt || return

    echo -e "\033[33;1mTarring Coverity Scan Analysis results...\033[0m"
    tar czf $results_archive $results_dir || return

    echo -e "\033[33;1mUploading Coverity Scan Analysis results...\033[0m"
    response=$(curl \
               --silent --write-out "\n%{http_code}\n" \
               --form project=$COVERITY_SCAN_PROJECT_NAME \
               --form token=$COVERITY_SCAN_TOKEN \
               --form email=$COVERITY_SCAN_EMAIL \
               --form file=@$results_archive \
               --form version=$sha \
               --form description="Daily build" \
               https://scan.coverity.com/builds)
    printf "\033[33;1mThe response is\033[0m\n%s\n" "$response"
    status_code=$(echo "$response" | sed -n '$p')
    if [ "$status_code" != "200" ]; then
        echo -e "\033[33;1mCoverity Scan upload failed: $(echo "$response" | sed '$d').\033[0m"
        return 1
    fi

    echo -e "\n\033[33;1mCoverity Scan Analysis completed successfully.\033[0m"
    set -x
}

for phase in "${PHASES[@]}"; do
    case $phase in
        SETUP)
            bash -c "echo 'deb-src http://archive.ubuntu.com/ubuntu/ $RELEASE main restricted universe multiverse' >>/etc/apt/sources.list"
            apt-get -y update
            apt-get build-dep -y --no-install-recommends elfutils
            apt-get -y install "${ADDITIONAL_DEPS[@]}"
            ;;
        RUN_GCC|RUN_CLANG|RUN_GCC_VALGRIND|RUN_CLANG_VALGRIND)
            export CC=gcc
            export CXX=g++
            if [[ "$phase" =~ ^RUN_CLANG ]]; then
                export CC=clang
                export CXX=clang++
                # elfutils is failing to compile with clang with -Werror
                # https://sourceware.org/pipermail/elfutils-devel/2021q1/003538.html
                # https://reviews.llvm.org/D97445
                #
                # -g -O2: https://sourceware.org/bugzilla/show_bug.cgi?id=23914
                # -gdwarf-4 instead of -g: https://bugs.kde.org/show_bug.cgi?id=452758
                flags="-O2 -gdwarf-4 ${CLANG_NO_ERROR_FLAGS[@]}"
                export CFLAGS="$flags"
                export CXXFLAGS="$flags"
            fi

            if [[ "$phase" =~ VALGRIND$ ]]; then
                additional_configure_flags="--enable-valgrind"
            fi

            $CC --version
            autoreconf -i -f
            ./configure --enable-maintainer-mode $additional_configure_flags
            make -j$(nproc) V=1
            make V=1 VERBOSE=1 check

            if [[ ! "$phase" =~ VALGRIND$ ]]; then
                make V=1 VERBOSE=1 distcheck
            fi
            ;;
        RUN_GCC_ASAN_UBSAN|RUN_CLANG_ASAN_UBSAN)
            export CC=gcc
            export CXX=g++

            # strict_string_checks= is off due to https://github.com/evverx/elfutils/issues/9
            export ASAN_OPTIONS="detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1"

            export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

            common_flags="-g -O1 -fno-omit-frame-pointer"
            export CFLAGS="$common_flags"
            export CXXFLAGS="$common_flags"

            if [[ "$phase" = "RUN_GCC_ASAN_UBSAN" ]]; then
                additional_configure_flags="--enable-sanitize-undefined --enable-sanitize-address"
            elif [[ "$phase" = "RUN_CLANG_ASAN_UBSAN" ]]; then
                export CC=clang
                export CXX=clang++

                # https://github.com/evverx/elfutils/issues/16
                # https://github.com/evverx/elfutils/issues/15
                sanitize_flags="-fsanitize=address,undefined -fno-sanitize=pointer-overflow -fno-sanitize=vla-bound"

                clang_flags="$common_flags $sanitize_flags ${CLANG_NO_ERROR_FLAGS[@]}"
                export CFLAGS="$clang_flags"
                export CXXFLAGS="$clang_flags"

                # There should probably be a better way to turn off unaligned access
                sed -i 's/\(check_undefined_val\)=[0-9]/\1=1/' configure.ac

                # https://github.com/evverx/elfutils/issues/11
                sed -i 's/^\(ZDEFS_LDFLAGS=\).*/\1/' configure.ac
                sed -i 's/^\(NO_UNDEFINED=\).*/\1/' configure.ac

                # https://github.com/evverx/elfutils/issues/13
                sed -i 's/ test-nlist / /' tests/Makefile.am
            fi

            $CC --version
            autoreconf -i -f
            if ! ./configure --enable-maintainer-mode $additional_configure_flags; then
                cat config.log
                exit 1
            fi

            if [[ "$phase" = "RUN_GCC_ASAN_UBSAN" ]]; then
                make -j$(nproc) V=1
            elif [[ "$phase" = "RUN_CLANG_ASAN_UBSAN" ]]; then
                # https://github.com/evverx/elfutils/issues/20
                ASAN_OPTIONS="$ASAN_OPTIONS:detect_leaks=0" make -j$(nproc) V=1
            fi

            make V=1 VERBOSE=1 check
            ;;
        COVERITY)
            coverity_install_script
            autoreconf -i -f
            ./configure --enable-maintainer-mode
            run_coverity
            ;;
        *)
            echo >&2 "Unknown phase '$phase'"
            exit 1
    esac
done
