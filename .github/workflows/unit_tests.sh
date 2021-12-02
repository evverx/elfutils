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
        RUN_GCC|RUN_CLANG)
            export CC=gcc
            export CXX=g++
            if [[ "$phase" = "RUN_CLANG" ]]; then
                export CC=clang
                export CXX=clang++
                # elfutils is failing to compile with clang with -Werror
                # https://sourceware.org/pipermail/elfutils-devel/2021q1/003538.html
                # https://reviews.llvm.org/D97445
                #
                # -g -O2: https://sourceware.org/bugzilla/show_bug.cgi?id=23914
                #
                # -fno-addrsig to fix "section [22] '.llvm_addrsig' has unsupported type 1879002115"
                flags="-Wno-error -g -O2 -fno-addrsig"
                export CFLAGS="$flags"
                export CXXFLAGS="$flags"
            fi

            $CC --version
            autoreconf -i -f
            ./configure --enable-maintainer-mode
            make -j$(nproc) V=1
            if ! make V=1 check; then
                cat tests/test-suite.log
                exit 1
            fi

            # elfutils fails to compile with clang and --enable-sanitize-undefined
            if [[ "$phase" != "RUN_CLANG" ]]; then
                make V=1 distcheck
            fi
            ;;
        RUN_GCC_ASAN_UBSAN)
            export CC=gcc
            export CXX=g++
            export ASAN_OPTIONS=detect_leaks=0 # ideally it shouldn't be neccessary
            export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1
            flags="-g -O1 -fsanitize=address,undefined"
            export CFLAGS="$flags"
            export CXXFLAGS="$flags"

            # There should probably be a better way to turn off unaligned access
            sed -i 's/\(check_undefined_val\)=[0-9]/\1=1/' configure.ac

            # test-nlist fails to run under ASan with gcc with:
            #
            # ==736897==ASan runtime does not come first in initial library list; you should
            # either link runtime to your application or manually preload it with LD_PRELOAD.
            #
            # and fails to compile with clang
            sed -i 's/ test-nlist / /' tests/Makefile.am

            # https://github.com/evverx/elfutils/issues/8
            for f in run-debuginfod-archive-groom.sh run-debuginfod-archive-rename.sh run-debuginfod-archive-test.sh; do
                printf "exit 77\n" >"tests/$f"
            done

            $CC --version
            autoreconf -i -f
            ./configure --enable-maintainer-mode
            make -j$(nproc) V=1
            if ! make V=1 check; then
                cat tests/test-suite.log
                exit 1
            fi
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
