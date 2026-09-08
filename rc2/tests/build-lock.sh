# Shared by verify.sh/bench.sh: a `flock`-based lock guarding their own
# `idris2 --build rc2.ipkg`/`--install` step, which writes into the
# shared `rc2/build/`/`install/` directories. Two such builds running
# concurrently (two sessions, or a session plus a subagent each
# rebuilding to verify their own separate change) were found to
# corrupt the resulting `idris2-rc2.so` (left 0 bytes, or with its
# executable bit stripped) when one process's own `--install` step
# overwrote files the other's `--build` was still mid-write on -- see
# TODO.md's own "verify.sh/bench.sh の並行実行対策" entry for the
# incident this fixes.
#
# Usage: `source` this file (needs `$RC2_DIR` already set), then call
# `acquire_build_lock` immediately before the actual build/install
# step -- only when that step is actually about to run (guard it with
# the caller's own `--skip-build` check first; a `--skip-build` run
# only reads an already-built binary, never writes, so it never needs
# this lock).
acquire_build_lock() {
    local lockfile="$RC2_DIR/build/.build.lock"
    mkdir -p "$RC2_DIR/build"
    exec 9>"$lockfile"
    if ! flock -w 600 9; then
        echo "error: another verify.sh/bench.sh build is still holding $lockfile after 600s -- if you only need to run tests/benchmarks against an already-built idris2-rc2, pass --skip-build to skip this lock entirely" >&2
        exit 2
    fi
}
