#!/bin/sh

. $srcdir/test-subr.sh

# Valgrind is turned off because hongfuzz keeps track of
# processes and signals they receive and valgrind shouldn't
# interfer with that. Apart from that it reports memory leaks
# in timeout we aren't interested in:
#==53620== 8 bytes in 1 blocks are definitely lost in loss record 1 of 1
#==53620==    at 0x483B7F3: malloc (in /usr/lib/x86_64-linux-gnu/valgrind/vgpreload_memcheck-amd64-linux.so)
#==53620==    by 0x4860959: timer_create@@GLIBC_2.3.3 (timer_create.c:59)
#==53620==    by 0x10AFCD: ??? (in /usr/bin/timeout)
#==53620==    by 0x10AC18: ??? (in /usr/bin/timeout)
#==53620==    by 0x48B00B2: (below main) (libc-start.c:308)
#==53620==
unset VALGRIND_CMD

# honggfuzz sets ASAN and UBSAN options compatible with it
# so they are reset early to prevent the environment from
# affecting the test
unset ASAN_OPTIONS
unset UBSAN_OPTIONS

timeout=30

# run_one is used to process files without honggfuzz
# to get backtraces that otherwise can be borked in honggfuzz runs
# so it has to set ASAN and UBSAN options itself
run_one()
{
    testrun timeout -s9 $timeout env \
        ASAN_OPTIONS=allocator_may_return_null=1 \
        UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1 \
        ${abs_builddir}/fuzz-dwfl-core "$1"
}

# Here the fuzz target processes files one by one to be able
# to catch memory leaks and other issues that can't be discovered
# with honggfuzz.
exit_status=0
for file in ${abs_srcdir}/fuzz-dwfl-core-crashes/*; do
    run_one $file || { echo "*** failure in $file"; exit_status=1; }
done

if [ -n "$honggfuzz" ]; then
    tempfiles log

    testrun $honggfuzz --run_time ${FUZZ_TIME:-180} -n 1 -v --exit_upon_crash \
            -i ${abs_srcdir}/fuzz-dwfl-core-crashes/ \
            -t $timeout --tmout_sigvtalrm \
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

if [ -n "$afl_fuzz" ]; then
    common_san_opts="abort_on_error=1:malloc_context_size=0:symbolize=0:allocator_may_return_null=1"
    handle_san_opts="handle_segv=0:handle_sigbus=0:handle_abort=0:handle_sigfpe=0:handle_sigill=0"
    testrun timeout --preserve-status ${FUZZ_TIME:-180} \
	    env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
	        ASAN_OPTIONS="$common_san_opts:$handle_san_opts:detect_leaks=0:detect_odr_violation=0" \
	        UBSAN_OPTIONS="$common_san_opts:$handle_san_opts:halt_on_error=1" \
	    $afl_fuzz -i ${abs_srcdir}/fuzz-dwfl-core-crashes/ \
	    -t $(expr $timeout '*' 1000) \
	    -m none \
	    -o OUT \
	    -- ${abs_builddir}/fuzz-dwfl-core @@

    afl-whatsup OUT/crashes

    rm -rf OUT
fi

exit $exit_status
