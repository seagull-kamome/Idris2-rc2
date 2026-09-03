#!/usr/bin/env bash
# One-shot performance measurement for rc2: builds the compiler
# (unless --skip-build), compiles each rc2/tests/Bench*.idr with both
# idris2-rc2 and real `idris2 --cg refc`, times N runs of each (`time`,
# wall clock), and prints a plain table -- the same manual dance
# rc2/BENCHMARKS.md's own measurements have always been done with, just
# scripted so it doesn't cost a session's own reasoning each time.
#
# Usage: ./bench.sh [--skip-build] [--runs N] [--missing-containers]
#
# Must be run from inside a nix-shell (or equivalent -- plain PATH setup
# works too) that already provides everything this run needs, started
# ONCE by the caller around the whole script -- this script itself makes
# no internal nix-shell calls of its own (see rc2/tests/refc-suite/run.sh
# for the same pattern). What's needed: `idris2` (always -- even
# `--skip-build` only skips rc2's own build step, every benchmark's own
# real-`idris2 --cg refc` comparison side still runs unconditionally; the
# self-built one `env.sh` already puts on PATH, sourced below, normally
# satisfies this with nothing extra to add), `gcc`, `gmp`, `pkg-config`
# (always, for compiling rc2 itself and every benchmark), and `chez`
# (only under `--missing-containers`, for its own chez-backend
# comparison side). E.g.:
#
#   nix-shell -p gcc gmp pkg-config --run './bench.sh'
#
# or, if you don't already have an `idris2` on PATH (e.g. no self-built
# one under install/ yet), add it to that list:
#
#   nix-shell -p idris2 gcc gmp pkg-config --run './bench.sh'
#
# and under --missing-containers, add chez too:
#
#   nix-shell -p idris2 gcc gmp pkg-config chez --run './bench.sh --missing-containers'
#
#   --skip-build           Don't rebuild idris2-rc2 first.
#   --runs N                Repeat each binary N times (default 3).
#   --missing-containers    Also run the idris2-missing-containers
#                            external-package benchmark (rc2/BENCHMARKS.md's
#                            own "外部パッケージベンチマーク" methodology).
#                            Requires install/idris2-missing-containers
#                            to already be cloned (clones it if missing,
#                            per rc2/BENCHMARKS.md's own セットアップ) --
#                            always run from the package's own root
#                            directory (install/idris2-missing-containers/),
#                            never test/src/ or below -- Main.idr opens
#                            its own data files via package-root-relative
#                            paths with no error branch coded for a wrong
#                            cwd (see KNOWN-BUGS.md's own resolved-not-a-bug
#                            entry for exactly this mistake).
#
# Prints wall-clock averages per backend and the rc2-vs-refc speedup
# ratio. Not a pass/fail script (there's no "correct" answer to a timing
# number) -- read the table.
#
# Every generated artifact (compiled binaries, build logs) lands under
# rc2/tests/build/ -- cleaned at the very start of a run (same
# directory rc2/tests/verify.sh also uses, so whichever of the two you
# run last is the one whose artifacts are left behind), then left
# alone for post-run inspection rather than deleted on exit.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$RC2_DIR/.." && pwd)"
IDRIS2RC2="$RC2_DIR/build/exec/idris2-rc2"

SKIP_BUILD=0
RUNS=3
DO_MISSING_CONTAINERS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --runs) RUNS="$2"; shift 2 ;;
        --missing-containers) DO_MISSING_CONTAINERS=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Both rc2 itself (the "Build" step below) and every benchmark's own
# real-refc/chez comparison side use whichever `idris2` is first on
# PATH -- e.g. a self-built one -- so a locally-built compiler under
# test can be picked up just by adjusting PATH before invoking this
# script. Fail fast with a clear error rather than a confusing
# downstream build failure if that's not set up. Comparisons always run
# (no flag skips them), so this check isn't conditioned on --skip-build
# the way verify.sh's is.
if ! command -v idris2 > /dev/null 2>&1; then
    echo "error: no 'idris2' on PATH -- put one on PATH before running this script" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "$REPO_DIR/env.sh"

echo "=== Build ==="
if [ "$SKIP_BUILD" -eq 1 ]; then
    echo "SKIP  build (--skip-build)"
else
    # rc2.ipkg's own postbuild/postinstall hooks build and install
    # support/rc2's runtime (libidris2rc2.a) as a side effect of these
    # two calls (see README.md's "Building and running" section) --
    # both are needed here (unlike a lone `--build`) so this script is
    # self-contained and doesn't silently depend on rc2/tests/verify.sh
    # having already installed the runtime in a prior run.
    (cd "$RC2_DIR" && IDRIS2_PREFIX="$REPO_DIR/install" \
        idris2 --build rc2.ipkg) \
        > "$RC2_DIR/tests/bench-build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (see rc2/tests/bench-build.log)"
        exit 1
    fi
    (cd "$RC2_DIR" && IDRIS2_PREFIX="$REPO_DIR/install" \
        idris2 --install rc2.ipkg) \
        >> "$RC2_DIR/tests/bench-build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (runtime install, see rc2/tests/bench-build.log)"
        exit 1
    fi
    echo "OK    build (idris2-rc2 + libidris2rc2.a)"
fi

TMP="$RC2_DIR/tests/build"
rm -rf "$TMP"
mkdir -p "$TMP"

# Average wall-clock seconds of $RUNS invocations of "$@", via bash's
# own builtin `time` (TIMEFORMAT set to just the real-time seconds).
avg_time() {
    local total="0"
    local i
    for ((i = 0; i < RUNS; i++)); do
        local t
        TIMEFORMAT='%R'
        t="$( { time "$@" > /dev/null 2>&1; } 2>&1 )"
        total="$(awk -v a="$total" -v b="$t" 'BEGIN { printf "%.4f", a + b }')"
    done
    awk -v t="$total" -v n="$RUNS" 'BEGIN { printf "%.4f", t / n }'
}

echo
echo "=== Micro-benchmarks (rc2/tests/Bench*.idr, $RUNS run(s) each) ==="
printf '%-14s %10s %10s %8s\n' "benchmark" "rc2(s)" "refc(s)" "speedup"
for bf in "$RC2_DIR"/tests/Bench*.idr; do
    name="$(basename "$bf" .idr)"
    "$IDRIS2RC2" --cg rc2 "$bf" -o "$TMP/${name}_rc2" > "$TMP/${name}_rc2_build.log" 2>&1
    idris2 --cg refc "$bf" -o "$TMP/${name}_refc" > "$TMP/${name}_refc_build.log" 2>&1
    if [ ! -x "$TMP/${name}_rc2" ] || [ ! -x "$TMP/${name}_refc" ]; then
        printf '%-14s %10s %10s %8s\n' "$name" "BUILD-FAIL" "-" "-"
        continue
    fi
    rc2_t="$(avg_time "$TMP/${name}_rc2")"
    refc_t="$(avg_time "$TMP/${name}_refc")"
    speedup="$(awk -v r="$refc_t" -v c="$rc2_t" 'BEGIN { if (c > 0) printf "%.2fx", r / c; else print "n/a" }')"
    printf '%-14s %10s %10s %8s\n' "$name" "$rc2_t" "$refc_t" "$speedup"
done

if [ "$DO_MISSING_CONTAINERS" -eq 1 ]; then
    echo
    echo "=== idris2-missing-containers (external package) ==="
    MCT_DIR="$REPO_DIR/install/idris2-missing-containers"
    if [ ! -d "$MCT_DIR" ]; then
        echo "Cloning idris2-missing-containers into install/ ..."
        git clone https://github.com/seagull-kamome/idris2-missing-containers.git "$MCT_DIR" \
            > "$RC2_DIR/tests/bench-mct-clone.log" 2>&1
        if [ ! -d "$MCT_DIR" ]; then
            echo "FAIL  clone (see rc2/tests/bench-mct-clone.log)"
            exit 1
        fi
    fi

    echo "Installing missing-containers.ipkg via idris2-rc2 ..."
    (cd "$MCT_DIR" && "$IDRIS2RC2" --install missing-containers.ipkg) \
        > "$RC2_DIR/tests/bench-mct-install.log" 2>&1

    echo "Building 3 backends (rc2/refc/chez) ..."
    (cd "$MCT_DIR/test/src" && "$IDRIS2RC2" --cg rc2 -p missing-containers -p contrib Main.idr -o mct_rc2) \
        > "$RC2_DIR/tests/bench-mct-build-rc2.log" 2>&1
    (cd "$MCT_DIR/test/src" && idris2 --cg refc -p missing-containers -p contrib Main.idr -o mct_refc) \
        > "$RC2_DIR/tests/bench-mct-build-refc.log" 2>&1
    (cd "$MCT_DIR/test/src" && idris2 -p missing-containers -p contrib Main.idr -o mct_chez) \
        > "$RC2_DIR/tests/bench-mct-build-chez.log" 2>&1

    rc2_bin="$MCT_DIR/test/src/build/exec/mct_rc2"
    refc_bin="$MCT_DIR/test/src/build/exec/mct_refc"
    chez_bin="$MCT_DIR/test/src/build/exec/mct_chez"
    if [ ! -x "$rc2_bin" ] || [ ! -x "$refc_bin" ] || [ ! -x "$chez_bin" ]; then
        echo "FAIL  one or more backend builds failed (see rc2/tests/bench-mct-build-*.log)"
        exit 1
    fi

    # Critical: run from the package's own ROOT, not test/src/ -- Main.idr
    # opens its own data files via package-root-relative paths. See this
    # script's own header comment / KNOWN-BUGS.md.
    printf '%-14s %10s\n' "backend" "avg(s)"
    for label_bin in "rc2:$rc2_bin" "refc:$refc_bin" "chez:$chez_bin"; do
        label="${label_bin%%:*}"
        bin="${label_bin#*:}"
        t="$(cd "$MCT_DIR" && avg_time "$bin")"
        printf '%-14s %10s\n' "$label" "$t"
    done
fi
