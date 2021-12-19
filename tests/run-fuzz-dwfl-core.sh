#!/bin/sh

. $srcdir/test-subr.sh

# honggfuzz sets ASAN and UBSAN options compatible with it
# so they are reset early to prevent the environment from
# affecting the test
unset ASAN_OPTIONS
unset UBSAN_OPTIONS

# run_one is used to process files without honggfuzz
# to get backtraces that otherwise can be borked in honggfuzz runs
# so it has to set ASAN and UBSAN options itself
run_one()
{
    testrun env \
        ASAN_OPTIONS=allocator_may_return_null=1 \
        UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1 \
        ${abs_builddir}/fuzz-dwfl-core "$1"
}

# Here the fuzz target processes files one by one to be able
# to catch memory leaks and other issues that can't be discovered
# with honggfuzz. This part can be run under ASan/UBSan/Valgrind
# so it is never skipped
exit_status=0
for file in ${abs_srcdir}/fuzz-dwfl-core-crashes/*; do
    run_one $file || { echo "*** failure in $file"; exit_status=1; }
done

# Here Valgrind is turned off because
# hongfuzz keeps track of processes and signals they receive
# and valgrind shouldn't interfer with that
unset VALGRIND_CMD

if [ -n "$honggfuzz" ]; then
    tempfiles log

    testrun $honggfuzz --run_time ${FUZZ_TIME:-180} -n 1 -v --exit_upon_crash \
            -i ${abs_srcdir}/fuzz-dwfl-core-crashes/ \
            -t 30 \
            -o OUT \
            --logfile log \
            -- ${abs_builddir}/fuzz-dwfl-core ___FILE___

    rm -rf OUT

    # hongfuzz always exits successfully so to tell "success" and "failure" apart
    # it's necessary to look for reports it leaves when processes it monitors crash.
    # Eventually it will be possible to pass --exit_code_upon_crash, which combined
    # with --exit_upon_crash can be used to get honggfuzz to fail, but it hasn't been
    # released yet. Initially it was used but on machines with the latest stable release
    # tests that should have failed passed, which led to https://github.com/google/honggfuzz/pull/432
    if [ -f HONGGFUZZ.REPORT.TXT ]; then
        tail -n 25 log
        cat HF.sanitizer.log* || true
        cat HONGGFUZZ.REPORT.TXT
        for crash in $(sed -n 's/^FUZZ_FNAME: *//p' HONGGFUZZ.REPORT.TXT); do
            run_one $crash || true
        done
        exit_status=1
    fi
fi

exit $exit_status
