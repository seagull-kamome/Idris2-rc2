# Sourced (not executed) by run.sh right before compiling this test --
# see run.sh's own optional-hooks support. Verifies Compiler.RC2.CC's
# own findCFlags/findLDFlags/findLDLibs correctly find and pass through
# the *bare* CFLAGS/LDFLAGS/LDLIBS env vars (the fallback CC.idr checks
# after IDRIS2_CFLAGS/IDRIS2_LDFLAGS/IDRIS2_LDLIBS, which every other
# rc2 test already exercises via its own companion-.c linking) -- both
# split correctly into multiple space-separated flags, and reach the
# actual C compiler invocations for the *generated* C file specifically
# (not just some other build step): `-I./library` lets that generated
# file's own #include "externalc.h" resolve, and `-lexternalc` (`-L`
# via LDFLAGS, the library name itself via LDLIBS) is what the final
# link actually resolves `add`/`fastfibsum` against -- if either env
# var failed to reach its compiler invocation, this would fail to
# compile or link, not silently produce a wrong answer.
export CFLAGS="-I${PWD}/library -O2 ${CFLAGS:-}"
export LDFLAGS="-L${PWD}/library ${LDFLAGS:-}"
export LDLIBS="-lexternalc ${LDLIBS:-}"
export LD_LIBRARY_PATH="${PWD}/library:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="${PWD}/library:${DYLD_LIBRARY_PATH:-}"
