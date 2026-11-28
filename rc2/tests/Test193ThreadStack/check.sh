#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
#
# Runs the program under the stack limits and IDRIS2RC2_THREAD_STACK
# values where the runtime's choice of a thread's stack shows
# (rc2/doc/concurrency.md, "Thread stacks"). verify.sh's own run, at
# whatever limit it was started under, cannot tell.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

bin="$TMP/${name}_rc2"
ulimit -c 0

both() { printf 'fork: %s\nforkJoin: %s' "$1" "$1"; }
expect() { # expect LABEL WANT GOT
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: got '$(echo "$3" | tr '\n' ';')'"; fi
}

# 100,000 levels take 4.8 MB (48 bytes a level, gcc 15 at -O2): more than
# the 2 MB glibc gives a thread when the limit is unlimited, less than the
# runtime's 16 MB, and so for any frame of 21 to 167 bytes.
sum100k="$(both 5000050000)"
if (ulimit -s unlimited) 2>/dev/null; then
    expect "100,000 levels under ulimit -s unlimited" "$sum100k" \
        "$( (ulimit -s unlimited; "$bin" 100000) 2>&1)"
else
    echo "$name: ulimit -s unlimited is not allowed here, that check is skipped"
fi

# The override is not bounded by the limit.
expect "2,000,000 levels with IDRIS2RC2_THREAD_STACK=1G under ulimit -s 4096" "$(both 2000001000000)" \
    "$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=1G "$bin" 2000000) 2>&1)"

# A small override is obeyed too: the same recursion overflows.
# (`exit` keeps the inner shell alive to take the signal's report.)
(ulimit -s 4096; IDRIS2RC2_THREAD_STACK=128K "$bin" 100000; exit $?) > /dev/null 2>&1
status=$?
if [ "$status" -ge 128 ]; then
    pass "100,000 levels overflow with IDRIS2RC2_THREAD_STACK=128K"
else
    fail "100,000 levels with IDRIS2RC2_THREAD_STACK=128K: exit status $status, wanted a signal"
fi

# The sizes themselves, where the C library can tell (the companion C
# answers 0 where it cannot).
if [ "$("$bin" size 2>&1)" = "$(both 0)" ]; then
    echo "$name: no thread stack size on this C library, those checks are skipped"
    exit 0
fi
expect "the soft limit when it is finite" "$(both 4194304)" \
    "$( (ulimit -s 4096; "$bin" size) 2>&1)"
if (ulimit -s unlimited) 2>/dev/null; then
    expect "16 MB when the limit is unlimited" "$(both 16777216)" \
        "$( (ulimit -s unlimited; "$bin" size) 2>&1)"
fi
expect "IDRIS2RC2_THREAD_STACK=48M" "$(both 50331648)" \
    "$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=48M "$bin" size) 2>&1)"
expect "IDRIS2RC2_THREAD_STACK=48MB" "$(both 50331648)" \
    "$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=48MB "$bin" size) 2>&1)"
expect "IDRIS2RC2_THREAD_STACK=48mib" "$(both 50331648)" \
    "$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=48mib "$bin" size) 2>&1)"
expect "IDRIS2RC2_THREAD_STACK=3000000 is rounded up to a page" "$(both 3002368)" \
    "$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=3000000 "$bin" size) 2>&1)"
# The variable is read when the first thread starts, so a program can set it.
expect "the program sets IDRIS2RC2_THREAD_STACK=24M before its first thread" "$(both 25165824)" \
    "$( (ulimit -s 4096; "$bin" set 24M) 2>&1)"
# 0 leaves the size to pthread_create (glibc: 2 MB on most machines when the
# limit is unlimited).
if (ulimit -s unlimited) 2>/dev/null; then
    out="$( (ulimit -s unlimited; IDRIS2RC2_THREAD_STACK=0 "$bin" size) 2>&1)"
    if [ "$out" != "$(both 16777216)" ] && [ "$(echo "$out" | wc -l)" = 2 ]; then
        pass "IDRIS2RC2_THREAD_STACK=0 leaves the size to the C library"
    else
        fail "IDRIS2RC2_THREAD_STACK=0: got '$(echo "$out" | tr '\n' ';')'"
    fi
fi
# Not a size: said once on stderr, and the default is used.
out="$( (ulimit -s 4096; IDRIS2RC2_THREAD_STACK=12Q "$bin" size) 2>&1)"
expect "IDRIS2RC2_THREAD_STACK=12Q is reported and ignored" \
    "$(printf 'idris2rc2: IDRIS2RC2_THREAD_STACK="12Q" is not a size (bytes, or a number with K, M or G); ignored\n%s' "$(both 4194304)")" \
    "$out"
