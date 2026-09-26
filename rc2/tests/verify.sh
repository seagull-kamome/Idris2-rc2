#!/usr/bin/env bash
# One-shot correctness verification for rc2: builds the compiler and
# runtime, runs the refc-suite regression tests, compiles and diffs
# every smoke test (one per rc2/tests/TestN/ folder, e.g.
# rc2/tests/TestN/TestN.idr) against a saved expected output
# (rc2/tests/TestN/TestN.expected), and runs `valgrind
# --leak-check=full` on the leak-sensitive subset -- all the steps
# rc2/doc/*.md's own "Verification methodology" sections and past
# sessions have done by hand, in one deterministic, exit-code-driven
# script. See KNOWN-BUGS.md for every already-investigated quirk this
# script deliberately does NOT flag as a failure (pre-existing leak
# byte counts, Test7CastMatrix's own nixpkgs-RefC-library blocker,
# etc.) -- if KNOWN-BUGS.md changes, update the constants below to
# match.
#
# Usage: ./verify.sh [--skip-build] [--no-valgrind]
#                     [--valgrind-all] [--regen-expected] [--directive VALUE]...
#
# Must be run from inside a nix-shell (or equivalent -- plain PATH setup
# works too) that already provides everything this run needs, started
# ONCE by the caller around the whole script -- this script itself makes
# no internal nix-shell calls of its own (see rc2/tests/refc-suite/run.sh
# for the same pattern). What's needed: `idris2` (only when `--skip-build`
# is not given, or `--regen-expected` is given -- the self-built one
# `env.sh` already puts on PATH, sourced below, normally satisfies this
# with nothing extra to add), `gcc`, `gmp` (dev headers), `pkg-config`
# (all three always, for compiling rc2 itself and every smoke test), and
# `valgrind` (only unless `--no-valgrind` is given). E.g., for a normal
# full run:
#
#   nix-shell -p gcc gmp pkg-config valgrind --run './verify.sh'
#
# or, if you don't already have an `idris2` on PATH (e.g. no self-built
# one under install/ yet), add it to that list:
#
#   nix-shell -p idris2 gcc gmp pkg-config valgrind --run './verify.sh'
#
#   --skip-build       Don't rebuild idris2-rc2/libidris2rc2.a first
#                       (use the existing rc2/build/exec/idris2-rc2).
#   --no-valgrind      Skip the valgrind pass entirely (faster).
#   --valgrind-all     Run valgrind on every smoke test, not just the
#                       curated leak-sensitive subset.
#
# VALGRIND_JOBS=N (env var, not a flag) -- how many valgrind runs to
# execute concurrently (default: nproc/2, floored at 1). Each run is
# an independent single-threaded process on its own binary/log file,
# so this parallelizes cleanly; halved from nproc rather than matching
# it because valgrind's own per-process memory overhead is large
# enough that one instance per core risks swapping on a memory-
# constrained machine, which would erase the wall-clock win. Measured
# ~33% faster on the leak-sensitive subset (21 tests) at the default
# of 2 jobs on a 4-core/15GB box vs. the old fully-sequential loop.
#   --directive VALUE  Forwarded as `--directive VALUE` to idris2-rc2
#                       for every smoke test (rc2/tests/TestN/TestN.idr)
#                       compile -- repeatable, same convention as
#                       idris2's own `--directive` (e.g. `--directive
#                       noconaltnative --directive noloop`). See
#                       Compiler.RC2.RC2's own `toRCDefs` doc comment
#                       (rc2/src/Compiler/RC2/RC2.idr) for the
#                       recognised `no<stagename>` values (noinline/
#                       noconaltnative/nomutualloop/noloop/nosink/
#                       nodualabi/nodeadcode -- `noreuse` was retired,
#                       see that doc comment's own note on why), plus
#                       `nomain` (not a stage disable -- suppresses the
#                       generated C `main()` entirely, see
#                       rc2/doc/export-support.md's "Linking as a
#                       library" section and worked example) -- lets a
#                       session compare compile/
#                       run time with a given optimisation pass on vs.
#                       off. Not applied to refc-suite (its own run.sh
#                       runs as a separate process, untouched by this
#                       flag). Disabling a stage should never change a
#                       smoke test's own PASS/FAIL outcome -- if it
#                       does, that's a correctness bug in the disabled
#                       stage, not a script bug; report it as a normal
#                       FAIL rather than special-casing it.
#   --regen-expected   Rebuild each smoke test with real `idris2 --cg
#                       refc` too, and overwrite its own
#                       rc2/tests/TestN/TestN.expected with that run's
#                       output, before diffing rc2's own output against
#                       it as usual. Slower (every smoke test gets
#                       built twice, once per backend) -- normal runs
#                       skip real refc entirely and just diff against
#                       whatever's already saved. Run this after
#                       editing/adding a TestN/TestN.idr whose own
#                       expected output changed, or after adding a
#                       brand new TestN/TestN.idr in its own new
#                       rc2/tests/TestN/ folder (this script picks up
#                       every such folder under rc2/tests/
#                       automatically, but a new one has no .expected
#                       of its own yet -- without this flag it just
#                       reports FAIL "no saved .expected"). Never
#                       touches Test7CastMatrix/Test7CastMatrix.expected
#                       or Test17ConstFold/Test17ConstFold.expected --
#                       those two are saved
#                       by hand instead (real refc can't even build on
#                       this reference nixpkgs for the former; the
#                       latter deliberately diverges by backend on
#                       purpose -- see NO_REFC_DIFF_TESTS below for
#                       both).
#
# Exit code 0 iff every check passed (known pre-existing issues from
# KNOWN-BUGS.md excepted); non-zero otherwise. All output is plain text
# on stdout, PASS/FAIL/SKIP/KNOWN-prefixed lines, safe to grep. Each
# smoke test's own PASS/FAIL line also carries its compile/run wall-
# clock time -- informational only, never part of the pass/fail
# verdict.
#
# Every generated artifact (compiled binaries, build logs, valgrind
# logs, .diff files) lands under rc2/tests/build/ -- cleaned at the
# very start of a run, then left alone (not deleted on exit) so a
# failure's own compile log/diff/valgrind output is still there to
# read afterward. To rerun or inspect a single test by hand once
# rc2/build/exec/idris2-rc2 exists (each test lives in its own
# rc2/tests/TestN/ folder alongside its own TestN.expected and,
# optionally, TestN.c/TestN.h):
#
#   cd rc2/tests
#   ../build/exec/idris2-rc2 --cg rc2 TestN/TestN.idr -o build/TestN_rc2
#   ./build/TestN_rc2                         # compare by eye, or:
#   diff <(cat TestN/TestN.expected) <(./build/TestN_rc2)
#
# A smoke test whose own %foreign declarations need a real C
# implementation (not just an rc2/RefC-provided primitive) can supply
# one as TestN/TestN.c alongside TestN/TestN.idr -- compiled once per
# run and linked in automatically via IDRIS2_CFLAGS/IDRIS2_LDFLAGS.
# Most tests have no such file; this is a no-op for them.

set -u

# Must be run with cwd = this script's own directory (rc2/tests), e.g.
# `cd rc2/tests && ./verify.sh`, NOT `./rc2/tests/verify.sh` from the
# repo root or anywhere else. Most of this script only ever touches
# $RC2_DIR/$REPO_DIR-prefixed absolute paths, so cwd doesn't normally
# matter -- but a handful of tests' own `%cg rc2
# extraRuntime=<relative path>` source pragmas (e.g.
# Test31CgExtraRuntime's own
# `extraRuntime=Test31CgExtraRuntime/Test31CgExtraRuntimeSupport.c`,
# resolved relative to rc2/tests -- this script's own required cwd --
# since each test now lives one level deeper, under its own
# rc2/tests/TestN/ folder)
# get resolved by upstream's own Compiler.Common.getExtraRuntime via a
# plain Core.readFile on that string as-is -- i.e. relative to
# whatever the idris2-rc2 *process's* cwd is at compile time, not
# relative to the source file's own directory. Run from the wrong cwd
# and those tests fail with a misleading "File Not Found" that has
# nothing to do with whatever you were actually testing (confirmed by
# hand: running from the repo root instead of here breaks
# Test31CgExtraRuntime this way). Deliberately NOT `cd`-ed into
# automatically here -- this script won't change a cwd the caller
# didn't ask it to.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$RC2_DIR/.." && pwd)"
IDRIS2RC2="$RC2_DIR/build/exec/idris2-rc2"

SKIP_BUILD=0
DO_VALGRIND=1
VALGRIND_ALL=0
REGEN_EXPECTED=0
EXTRA_DIRECTIVES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --no-valgrind) DO_VALGRIND=0; shift ;;
        --valgrind-all) VALGRIND_ALL=1; shift ;;
        --regen-expected) REGEN_EXPECTED=1; shift ;;
        --directive) EXTRA_DIRECTIVES+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Both rc2 itself (the "Build" step below) and --regen-expected's own
# real-refc reference compile use whichever `idris2` is first on PATH --
# e.g. a self-built one -- so a locally-built compiler under test can be
# picked up just by adjusting PATH before invoking this script. Fail
# fast with a clear error rather than a confusing downstream build
# failure if that's not set up.
if { [ "$SKIP_BUILD" -eq 0 ] || [ "$REGEN_EXPECTED" -eq 1 ]; } && ! command -v idris2 > /dev/null 2>&1; then
    echo "error: no 'idris2' on PATH -- put one on PATH before running this script" >&2
    exit 2
fi

# Turned into a `--directive X --directive Y ...` array, spliced straight
# after `--directive dumprcexpr` in every smoke-test compile line below
# (never sent to refc-suite/run.sh, which runs as its own separate
# process). Kept as an array (not a joined string) since every compile
# below is now a direct argv-array invocation, not a string handed to
# `nix-shell --run` for its own `bash -c` to re-split.
directive_flags=()
for d in "${EXTRA_DIRECTIVES[@]}"; do
    directive_flags+=(--directive "$d")
done

# Wall-clock elapsed seconds between two `date +%s.%N` samples --
# avoided bash's own `time` builtin since it doesn't compose with the
# `actual="$(...)"` command substitution smoke tests already need to
# capture their own stdout.
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
timing_note() { echo "compile ${1}s, run ${2}s"; }

# shellcheck source=/dev/null
source "$REPO_DIR/env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/build-lock.sh"

# Pin the locale for the whole run. The rc2 runtime now does
# `setlocale(LC_ALL, "")` in idris2rc2_rtInit (support/rc2/runtime.c),
# so every compiled test's behaviour would otherwise follow whatever
# LC_* / LANG this shell happens to carry (nix-shell here resolves to
# en_US.UTF-8, not C). C.UTF-8 gives a UTF-8 LC_CTYPE with plain
# codepoint-order collation -- deterministic, and what
# Test82RuntimeLocale asserts. (Double<->String output is
# locale-independent by construction -- numeric.c does its own decimal
# conversion -- so this pin only affects regex / strftime / strerror.)
export LC_ALL=C.UTF-8

# libs/rc2base is installed by hand, once, into this repo's own
# install/ prefix (see the top-level README.md's "Building and
# running" section) -- the same prefix rc2 itself uses, which idris2
# searches by default, so no extra package-path setup is needed here.

# Every generated artifact lands here -- cleaned now, at the very
# start, then left alone for the rest of this run (and afterward, for
# post-mortem inspection) rather than deleted on exit.
TMP="$RC2_DIR/tests/build"
rm -rf "$TMP"
mkdir -p "$TMP"

pass=0
fail=0
known=0
failed_names=()

report_pass() { echo "PASS  $1"; pass=$((pass + 1)); }
report_fail() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail + 1)); failed_names+=("$1"); }
report_known() { echo "KNOWN $1 ($2 -- see KNOWN-BUGS.md)"; known=$((known + 1)); }

echo "=== Build ==="
if [ "$SKIP_BUILD" -eq 1 ]; then
    echo "SKIP  build (--skip-build)"
else
    # See build-lock.sh's own header comment -- guards the shared
    # rc2/build//install/ directories from a concurrent build.
    acquire_build_lock
    # rc2.ipkg's own postbuild/postinstall hooks build and install
    # support/rc2's runtime (libidris2rc2.a) as a side effect of these
    # two calls -- see README.md's "Building and running" section.
    # No IDRIS2_PREFIX override here -- the self-built idris2 that
    # env.sh puts on PATH already defaults to the *shared* install/
    # tree on its own (baked in at bootstrap time; `idris2 --prefix`
    # confirms it). Deriving it instead from this script's own
    # on-disk location (as a prior version did) breaks under a git
    # worktree checkout: $RC2_DIR there resolves to the worktree's own
    # directory, not the shared install/ env.sh and the compiler
    # itself already agree on.
    (cd "$RC2_DIR" && idris2 --build rc2.ipkg) \
        > "$TMP/build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (see rc2/tests/build/build.log)"
        exit 1
    fi
    report_pass "build (idris2-rc2)"

    (cd "$RC2_DIR" && idris2 --install rc2.ipkg) \
        > "$TMP/runtime-build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (runtime, see rc2/tests/build/runtime-build.log)"
        exit 1
    fi
    report_pass "build (libidris2rc2.a)"
fi

echo
echo "=== refc-suite ==="
(cd "$RC2_DIR/tests/refc-suite" && ./run.sh)
refc_suite_status=$?
if [ "$refc_suite_status" -ne 0 ]; then
    fail=$((fail + 1))
    failed_names+=("refc-suite")
fi

echo
echo "=== Smoke tests ==="

# NO_REFC_DIFF_TESTS skips diffing against real refc in favour of a
# saved .expected file, for three different reasons: Test7CastMatrix
# because nixpkgs' own RefC support library fails to compile at all
# (KNOWN-BUGS.md), Test17ConstFold because its own codegenChain
# deliberately embeds System.Info.codegen's own value (a ConstExtPrim
# regression check) -- "rc2" vs "refc" is real, correct divergence
# between backends, not something to diff away -- Test24CStructSupport
# because real RefC doesn't implement getField/setField at all (see
# rc2/doc/c-struct-support.md's "What's confirmed" -- this is the
# exact gap rc2 closes), so there's no real refc output to diff
# against in the first place. Test26GCPtrAliasString is a fourth
# reason: real RefC's own createCFunctions has the identical drop-
# before-pack ordering bug this test regression-checks rc2 for (see
# idris2-src/src/Compiler/RefC/RefC.idr, out of scope to fix there),
# so diffing against it would compare two buggy outputs instead of
# checking against a correctness oracle. Test28Utf8Strings is a fifth
# reason: it regression-checks rc2's own codepoint- (not byte-) indexed
# String primitives, a deliberate divergence from real RefC's own
# byte-wise ones -- see README.md's "Deliberate differences from
# upstream RefC" -- so a real-refc diff would be an expected mismatch,
# not a regression. Its own saved .expected was independently cross-
# checked against plain `idris2` (Chez, the spec-correct reference) for
# every line not involving its own companion-C-only malformed-string
# case (Chez has no `scheme:`-tagged binding for that one test-only
# foreign function, so there is nothing meaningful to diff there).
# Test26GCPtrAliasString's own former Test29GCAnyPtrReturn half
# (merged in, see that test's own doc comment) is a sixth reason, the
# same shape as its first half above: real RefC's own packCFType
# CFGCPtr case (idris2-src/src/Compiler/RefC/RefC.idr:783) has the
# identical GCPointer-vs-plain-Pointer packing mismatch that half
# regression-checks rc2 for -- diffing against it would hit the same
# bug there (out of scope to fix in that separate reference tree)
# instead of checking against a correctness oracle. Test31CgExtraRuntime and
# Test32CgInlineRuntime are a seventh reason, different in kind from
# the others above: real RefC never reads `--directive`/`%cg` at all
# (see README.md's "%cg rc2 directives" section), so their own bare
# %foreign call sites would hit a genuine *link* error under
# `idris2 --cg refc` (the C function their %cg rc2 extraRuntime=/
# inlineRuntime= directive injects for rc2 is simply never defined
# anywhere in RefC's own output) -- not a divergent-but-comparable
# output, so there is nothing to regen/diff against there at all.
# Test35NetworkLoopback is an eighth reason: this project's self-built
# reference idris2 (idris2-src, pinned at a specific commit) has a real
# bug of its own, unrelated to networking or rc2. It used to be a
# String-cast naming mismatch (`idris2_cast_string_to_Integer` vs.
# `idris2_cast_String_to_Integer`) reached via accept()'s own
# getSockAddr -> Network.Socket.Data.parseIPv4's `Cast String Integer`
# usage -- that one is now fixed upstream (commit 0781ad1, "[refc] Fix
# casts from String failing to compile (#3832)"), confirmed in
# idris2-src: both the call site and casts.h/casts.c are now
# consistently lowercase. The test still can't compile under real
# `idris2 --cg refc`, though, for a different, unrelated reason: an
# internal inconsistency within idris2-src itself between the
# Idris-level network package and its own C runtime -- libs/network/
# Network/FFI.idr's `prim__idrnet_send_bytes` %foreign declaration
# expects a 4-argument idrnet_send_bytes(sockfd, content, nbytes, flags
# : Bits32), but support/c/idris_net.h/idris_net.c still only
# declare/define the old 3-argument idrnet_send_bytes(int sockfd, void
# *data, int len) with no flags parameter at all -- still present at
# idris2-src's currently pinned commit (confirmed to be current
# origin/main HEAD, i.e. not yet fixed upstream as of this writing).
# Real `idris2 --cg refc` fails to compile any program exercising
# Network.Socket.sendBytes (which this test does via accept()'s own
# loopback exchange) with an implicit-declaration/argument-count error
# as a result. rc2's own codegen has no equivalent inconsistency and
# compiles this test cleanly. `.expected` here is rc2's own
# manually-verified-correct output (deterministic bind/listen/connect/
# send/recv transcript over a 127.0.0.1 loopback), saved by hand --
# same reasoning as Test7CastMatrix/Test17ConstFold above, there is no
# real-RefC output to diff against in the first place.
#
# Test42SupportMisc: exercises setEnv/unsetEnv, which real `idris2 --cg
# refc` cannot even compile -- upstream's own idris_support.h declares
# no prototype for idris2_setenv/idris2_unsetenv (idris_support.c
# defines both; System.idr's own %foreign targets them through that
# same header regardless), and unlike rc2 (which now declares them
# itself in idris2rc2_runtime.h, ahead of that #include, so its own
# build never sees the mismatch -- see that file's own comment) real
# RefC's build has no such workaround: gcc's implicit-declaration
# warning is treated as a hard error in this project's own reference
# toolchain, confirmed by direct `idris2 --cg refc` attempt. Not
# RefC/rc2-specific -- a genuine upstream defect this project works
# around for its own tests but can't fix. `.expected` here is rc2's own
# manually-verified-correct output, same reasoning as
# Test7CastMatrix/Test17ConstFold above.
#
# Test47ConstCFStringReturn: exercises binding a real `const char *`-
# returning C function, which real `idris2 --cg refc` cannot compile --
# RefC.idr's own `cTypeOfCFType CFString = "char *"` (no `const`,
# unchanged upstream) makes its generated wrapper declare a plain,
# non-const `char *` for a CFString return, so GCC's own
# -Wdiscarded-qualifiers ("initialization discards 'const' qualifier")
# is a hard -Werror failure there, confirmed by direct `idris2 --cg
# refc` attempt. rc2's own `EmitUtil.idr` now declares this `const char
# *` instead (this fix's whole point -- see TODO.md's git history /
# KNOWN-BUGS.md), so only rc2 can actually compile this test. `.expected`
# here is rc2's own manually-verified-correct output, same reasoning as
# Test7CastMatrix/Test17ConstFold above.
#
# Test59Export: exercises `%export`'s real native-C-ABI wrapper
# synthesis (rc2/doc/export-support.md), which real `idris2 --cg refc`
# doesn't implement at all -- RefC ignores the pragma entirely, so the
# companion .c file's own `extern` declarations of the generated
# `idris2rc2_test_*` wrappers would fail to link against a refc build.
# `.expected` here is rc2's own manually-verified-correct output, same
# reasoning as Test7CastMatrix/Test17ConstFold above. This one merged
# test covers every %export CFType shape (scalars, Ptr, a C struct
# handle, a GCPtr argument, Integer both directions, a String return
# and a String argument) -- real `idris2 --cg refc` doesn't implement
# `%export` marshalling for any of them.
# Test3Data / Test8EmptyCon / Test27FFIDualABI / Test49IntegerOpReuse /
# Test66ClosureFastPath / Test83DoubleString print a Double
# via show/cast, and rc2's Double->String (support/rc2/numeric.c) is now
# the shortest round-tripping decimal, deliberately unlike RefC's fixed
# "%f" six-digit form -- see the top-level README's "Deliberate
# differences from upstream RefC". No shared baseline, so these check
# against the saved .expected only.
NO_REFC_DIFF_TESTS="Test3Data Test7CastMatrix Test8EmptyCon Test17ConstFold Test24CStructSupport Test26GCPtrAliasString Test27FFIDualABI Test28Utf8Strings Test31CgExtraRuntime Test32CgInlineRuntime Test35NetworkLoopback Test42SupportMisc Test47ConstCFStringReturn Test49IntegerOpReuse Test59Export Test66ClosureFastPath Test82RuntimeLocale Test83DoubleString Test84CgExternStruct Test85CgExternStructPtrField Test86CafMemoization"

# Leak-sensitive by design (reference-counting/reuse/native-shadow
# regression tests) -- checked with valgrind by default even without
# --valgrind-all. Test59Export's own CFInteger and CFString sections
# are the genuinely UAF-sensitive part -- the mpz-copy-in helper
# (idris2rc2_mkIntegerFromMpz) and the mpz_set-then-drop Integer-return
# path, and the independent-copy-then-drop String-return path, are
# exactly the shapes that would previously double-free or hand back a
# dangling pointer if the naive generic pack/extract-then-drop path had
# been used unmodified. Its CFPtr/CFStruct/CFGCPtr sections carry no
# comparable UAF risk of their own (no new copy/drop ordering, just the
# pre-existing CFPtr-shaped packCFType/extractValue reused as-is) but
# the same run covers them anyway since their own argument-side
# packCFType allocation (idris2rc2_mkPointer/idris2rc2_mkGCPointer) is
# new to %export's own argument marshalling and worth the same
# scrutiny.
LEAK_SENSITIVE_TESTS="Test1Basics Test9SelfTailLoop Test11DualABILeak Test12ConAltNative Test13NativeArgChain Test14SmallFunctionInline Test15CompareFusionThroughCall Test16LoopContinuePostDrop Test17ConstFold Test18ClosureInPlaceGrow Test19LoopInvariantParam Test22BranchSinking Test24CStructSupport Test26GCPtrAliasString Test27FFIDualABI Test28Utf8Strings Test33WideDualABIWorker Test35NetworkLoopback Test36ReuseOfferUniqueLeak Test37SystemMisc Test41FFIMalloc Test42SupportMisc Test44IORefExtPrimLeak Test46FastPackUnconditional Test49IntegerOpReuse Test57LoopCallArgNativeShadow Test59Export Test66ClosureFastPath Test69ConstFoldClosure Test70ConstFoldClosureCallthrough Test79DupMerge Test84CgExternStruct Test85CgExternStructPtrField Test86CafMemoization Test87SpecConstCon Test88KnownConFold Test89CafDualABI Test90StructReturn Test91IntConstFold Test92ArityRaise Test93ApplyFold Test94LoopConstClosureParam Test95Trmc"

# KNOWN-BUGS.md's own remaining pre-existing leaks -- "definitely
# lost" byte count, exactly. Anything else non-zero is a genuine new
# failure. (Test9SelfTailLoop's own former 784-byte entry was
# root-caused and fixed -- RLoopContinue's own missing postDrop field,
# see KNOWN-BUGS.md -- and is expected to be clean now.)
#
# Test28Utf8Strings/Test35NetworkLoopback/Test37SystemMisc's own former
# Test40SystemProcess half used to have entries here for the
# fastPack/fastConcat leak (Test28's own `pack` calls; Test35's via
# `Network.Socket.Data.parseIPv4`; Test40's via `System.File.ReadWrite`'s
# `fRead'`, the latter two originating
# inside the pre-compiled `network`/`base` packages' own already-
# elaborated code). All three are genuinely clean (0 bytes) now, not
# just KNOWN: Compiler.RC2.Emit's own `createCFunctions` intercepts
# `Prelude.Types.fastPack`/`fastConcat` by full name+signature at
# C-emission time and redirects to rc2's own leak-free
# `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` unconditionally, project-wide --
# reaching every call site regardless of which package it originates
# from, unlike the retired `Prelude.Fix.RC2` module's own `%transform`,
# which could only ever rewrite a call site within its own importer's
# elaboration scope. See KNOWN-BUGS.md / rc2/doc/fastpack-fix.md for
# the full writeup. Test46FastPackUnconditional is this fix's own
# dedicated regression test (no opt-in import at all, unlike the
# retired module).
#
# Test1Basics no longer needs an entry here either: its own 40-byte leak
# (KNOWN-BUGS.md's prior attribution to fastPack/fastConcat was wrong --
# it was actually the RExtPrim ownership-annotation gap, see
# doc/c-struct-support.md's own addendum) is genuinely fixed now, not
# just reclassified.
declare -A KNOWN_LEAK_BYTES=( )

is_in() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

ALL_TESTS="$(cd "$RC2_DIR/tests" && ls -d Test*/ 2>/dev/null | sed 's#/$##' | sort)"

for name in $ALL_TESTS; do
    compile_t0="$(date +%s.%N)"
    # A companion C file ($name.c) supplies the actual C-side
    # implementation a %foreign declaration needs (e.g. a struct
    # constructor/destructor establishing a struct name for
    # getField/setField -- see rc2/doc/c-struct-support.md). Compiled
    # once here and linked in via IDRIS2_CFLAGS/IDRIS2_LDFLAGS, the
    # same environment variables Compiler.RC2.CC's own
    # findCFlags/findLDFlags already read -- most tests have no such
    # file, so this is a no-op for them. Reused below for the real
    # `idris2 --cg refc` --regen-expected invocation too, not just
    # rc2's own -- a companion-C test with nothing else disqualifying
    # it from NO_REFC_DIFF_TESTS still needs the same header/object
    # available to compile against the real reference compiler.
    companion_env=()
    if [ -f "$RC2_DIR/tests/$name/$name.c" ]; then
        gcc -c "$RC2_DIR/tests/$name/$name.c" -o "$TMP/${name}_companion.o" \
            > "$TMP/${name}_companion_compile.log" 2>&1
        if [ $? -ne 0 ]; then
            report_fail "$name" "companion C file failed to compile, see $TMP/${name}_companion_compile.log"
            continue
        fi
        companion_env=("IDRIS2_LDFLAGS=$TMP/${name}_companion.o" "IDRIS2_CFLAGS=-I$RC2_DIR/tests/$name")
    fi
    # $IDRIS2RC2 is invoked directly (an already-built binary), not via
    # a bare `idris2` command -- just needs the C toolchain (gcc/gmp/
    # pkg-config) already on PATH from the caller's own nix-shell.
    env "${companion_env[@]}" "$IDRIS2RC2" --cg rc2 -p network -p linear -p rc2base \
        --directive dumprcexpr "${directive_flags[@]}" "$RC2_DIR/tests/$name/$name.idr" -o "$TMP/${name}_rc2" \
        > "$TMP/${name}_compile.log" 2>&1
    compile_time="$(elapsed "$compile_t0" "$(date +%s.%N)")"
    if [ ! -x "$TMP/${name}_rc2" ]; then
        report_fail "$name" "rc2 compile error (compile ${compile_time}s), see $TMP/${name}_compile.log"
        continue
    fi

    # Test30CgPragma's own `%cg rc2 dumpdualabi` source pragma is the
    # ONLY thing that can produce this build's `.dualabi` dump file --
    # this compile never got `--directive dumpdualabi` on the CLI (only
    # the baked-in `--directive dumprcexpr` above, plus whatever
    # --directive flags this verify.sh run was given by hand, none of
    # which are dumpdualabi by default). Confirms Compiler.RC2.RC2's
    # `getDirectives (Other "rc2")` wiring actually picks up source-level
    # %cg rc2 directives, not just CLI ones.
    if [ "$name" = "Test30CgPragma" ]; then
        if [ -f "$TMP/${name}_rc2.dualabi" ]; then
            report_pass "$name (source %cg rc2 dumpdualabi honored -- $TMP/${name}_rc2.dualabi produced with no CLI --directive dumpdualabi)"
        else
            report_fail "$name" "source %cg rc2 dumpdualabi NOT honored -- $TMP/${name}_rc2.dualabi missing"
        fi
    fi

    # Test13NativeArgChain's own `classify`/`describe` regression-check
    # Compiler.RC2.DualABI's own constant-`case` scrutinee promotion
    # (`constCaseScrutineeNativeReads`, see that test's own comment):
    # both workers return a native scalar read only as a `case`
    # scrutinee, so no call site may box that result on the way out.
    # Invisible to an output diff -- boxing a scalar and immediately
    # unboxing it changes nothing a program can print.
    if [ "$name" = "Test13NativeArgChain" ]; then
        # `return idris2rc2_mk*(worker(...))` is the dual-ABI *wrapper*
        # itself -- presenting a Boxed ABI is its entire job (see
        # doc/dual-abi.md's Stage 3a), so it is excluded. What must not
        # appear is a *call site* boxing the result.
        boxed="$(grep -E 'idris2rc2_mk[A-Za-z0-9]+\(idris2rc2_worker_Main_(scaledAbs|isBig)_' \
                   "$TMP/${name}_rc2.c" | grep -cvE '^[[:space:]]*return ' || true)"
        # And the branching-value promotion: `describeBoth`'s whole body
        # is `&&` over two native predicate calls, so with the branch
        # itself promoted it holds no boxing and no Boxed intermediate
        # at all -- a native scalar from its entry to both its returns.
        # Scans between the definition's own `{` and `}`; the forward
        # declaration ends `);` instead and is skipped.
        bodyboxed="$(awk '
            /^IDRIS2RC2_Value \*Main_describeBoth$/ { seen=1; next }
            seen && /^\{[[:space:]]*$/ { inbody=1; seen=0; next }
            seen && /^\)[[:space:]]*;/ { seen=0 }
            inbody && /^\}[[:space:]]*$/ { inbody=0 }
            inbody && /idris2rc2_mk/ { c++ }
            inbody && /IDRIS2RC2_Value \* var_[0-9]+ = NULL;/ { c++ }
            END { print c+0 }' "$TMP/${name}_rc2.c")"
        if [ "$boxed" = "0" ] && [ "$bodyboxed" = "0" ]; then
            report_pass "$name (DualABI native promotion -- case-scrutinee and branching-value worker results stay native)"
        elif [ "$boxed" != "0" ]; then
            report_fail "$name" "DualABI boxed $boxed case-scrutinee worker result(s) in $TMP/${name}_rc2.c"
        else
            report_fail "$name" "DualABI left $bodyboxed boxing site(s) inside Main_describeBoth in $TMP/${name}_rc2.c"
        fi
    fi

    # Test79DupMerge's own Section 4 is the suite's ONLY exercise of
    # Compiler.RC2.DupMerge's `cancelDupDrop` peephole -- verified by
    # scanning every other test's dump and finding not one cancellable
    # pair. An output diff can't see the peephole at all (cancelling a
    # matched +1/-1 pair never changes what the program prints), so
    # without this the peephole could stop firing entirely and the whole
    # suite would still pass. Re-derives the peephole's own rule over
    # the dump: within a run of refcount-only nodes at one indent, no
    # `dup v` may still be followed by a `drop` releasing that same `v`.
    if [ "$name" = "Test79DupMerge" ]; then
        leftover="$(awk '
            function indent_of(s) { match(s, /^ */); return RLENGTH }
            /^ *dup v[0-9]+( x[0-9]+)?$/ {
                i = indent_of($0)
                if (i != ind) { delete pend; ind = i }
                pend[$2] += ($3 ~ /^x[0-9]+$/) ? substr($3, 2) + 0 : 1
                next
            }
            /^ *drop \[/ {
                i = indent_of($0)
                if (i != ind) { delete pend; ind = i; next }
                s = $0; sub(/^ *drop \[/, "", s); sub(/\]$/, "", s)
                k = split(s, vs, /, */)
                for (j = 1; j <= k; j++)
                    if (pend[vs[j]] > 0) { pend[vs[j]]--; bad++ }
                next
            }
            { delete pend; ind = -1 }
            END { print bad + 0 }
        ' "$TMP/${name}_rc2.rcexpr")"
        if [ "$leftover" = "0" ]; then
            report_pass "$name (DupMerge cancelDupDrop -- no dup left paired with a later drop of the same local)"
        else
            report_fail "$name" "DupMerge cancelDupDrop left $leftover dup/drop pair(s) uncancelled in $TMP/${name}_rc2.rcexpr"
        fi
    fi

    # Test87SpecConstCon is the suite's only exercise of
    # Compiler.RC2.SpecClosure's own constant-constructor
    # specialization (doc/constant-constructor-specialization.md).
    # Entirely invisible to an output diff -- dispatching a method
    # through idris2rc2_applyClosure and calling it directly print the
    # same thing -- so without this the pass could stop firing and the
    # whole suite would still pass. Two checks, because either alone
    # can be satisfied for the wrong reason: a clone must actually have
    # been built AND kept (the profitability gate discards most
    # attempts), and the boxed dispatch it exists to remove must be
    # gone from the generated C. `classify`'s two call sites pass two
    # distinct constant dictionaries, so both clones have to land.
    #
    # Like Test13's and Test79's checks above, this one asserts that a
    # stage *fired*, so `--directive nospecconstcon` makes it FAIL by
    # design -- that run is for confirming the stage doesn't change any
    # test's own output, and this line is the one expected exception.
    if [ "$name" = "Test87SpecConstCon" ]; then
        clones="$(grep -cE '^def \{rc2_specConst_' "$TMP/${name}_rc2.rcexpr" || true)"
        dispatches="$(grep -c 'idris2rc2_applyClosure' "$TMP/${name}_rc2.c" || true)"
        if [ "$clones" -ge 2 ] && [ "$dispatches" = "0" ]; then
            report_pass "$name (SpecConstCon -- $clones clone(s) kept, no boxed closure dispatch left)"
        elif [ "$clones" -lt 2 ]; then
            report_fail "$name" "SpecConstCon kept $clones clone(s), expected at least 2, in $TMP/${name}_rc2.rcexpr"
        else
            report_fail "$name" "SpecConstCon left $dispatches idris2rc2_applyClosure call(s) in $TMP/${name}_rc2.c"
        fi
    fi

    # Test88KnownConFold: ConstFold's known-constructor fold
    # (doc/constructor-escape-analysis.md, "Rewrite A") is invisible to
    # an output diff, so assert on the dump that `bump`'s non-escaping
    # `Just` is gone. Like Test87's check, `--directive noconstfold`
    # makes this FAIL by design.
    if [ "$name" = "Test88KnownConFold" ]; then
        justs="$(awk '/^def \{idris2rc2_worker_Main_bump:/{p=1; next} /^def /{p=0} p && /con _builtin.JUST/' "$TMP/${name}_rc2.rcexpr" | wc -l)"
        if [ "$justs" = "0" ]; then
            report_pass "$name (known-constructor fold -- bump's Just never built)"
        else
            report_fail "$name" "bump still builds $justs Just(s) in $TMP/${name}_rc2.rcexpr"
        fi
        # `score`'s chain result `Right (a + b)` is the only `Right`
        # built in a matched cell (`reuse=`); PushCon's push
        # (`--directive nopushcon` fails this) means it's never built.
        rights="$(awk '/^def \{idris2rc2_worker_Main_score:/{p=1; next} /^def /{p=0} p && /con Prelude.Types.Right .* reuse=/' "$TMP/${name}_rc2.rcexpr" | wc -l)"
        if [ "$rights" = "0" ]; then
            report_pass "$name (case pushed into tails -- score's chain result never built)"
        else
            report_fail "$name" "score still builds its chain result Right in $TMP/${name}_rc2.rcexpr"
        fi
    fi

    # Test89CafDualABI: DualABI's rewrites must reach inside a memoized
    # CAF body (doc/caf-memoization.md, "Limitations"). Both `abs` calls
    # in `table` spliced inline, none left as a call to the wrapper.
    if [ "$name" = "Test89CafDualABI" ]; then
        tableBody="$(awk '/^def Main.table /{p=1; next} /^def /{p=0} p' "$TMP/${name}_rc2.rcexpr")"
        inlined="$(grep -c 'callFFIInline' <<< "$tableBody" || true)"
        wrapped="$(grep -c 'call Main.prim__abs' <<< "$tableBody" || true)"
        if [ "$inlined" = "2" ] && [ "$wrapped" = "0" ]; then
            report_pass "$name (DualABI inside a memoized CAF -- both FFI calls inlined)"
        else
            report_fail "$name" "table has $inlined inlined and $wrapped wrapper FFI call(s) in $TMP/${name}_rc2.rcexpr"
        fi
    fi

    # Test90StructReturn: struct return (doc/struct-return.md) shows in the
    # dump as the workers that return a struct, and its width and layout:
    # `step`'s carries its `Int` natively (`Ret1:1=Int`), `lookupAge`'s
    # has a `Nothing` tail (`Ret1`), `halves`' two Boxed fields (`Ret2`),
    # `qr`'s two native ones (`Ret2:1=Int,Int`), and `segOf` shares
    # `shapeOf`'s three-field struct through a tail call
    # (`Ret3:1=Int,Int,Boxed:2=Int,Int,Int`); `halfOf` (only ever a
    # closure, so no caller gains) returns none. `--directive
    # nostructreturn` fails this.
    if [ "$name" = "Test90StructReturn" ]; then
        dump="$TMP/${name}_rc2.rcexpr"
        retOf() { grep -c "^def {idris2rc2_worker_Main_$1:[0-9]*} .* ret= $2 " "$dump" || true; }
        step="$(retOf step 'Ret1:1=Int')"
        lookupAge="$(retOf lookupAge Ret1)"
        halves="$(retOf halves Ret2)"
        qr="$(retOf qr 'Ret2:1=Int,Int')"
        segOf="$(retOf segOf 'Ret3:1=Int,Int,Boxed:2=Int,Int,Int')"
        shapeOf="$(retOf shapeOf 'Ret3:1=Int,Int,Boxed:2=Int,Int,Int')"
        halfOf="$(grep -c '^def .*Main_halfOf.* ret= Ret' "$dump" || true)"
        if [ "$step$lookupAge$halves$qr$segOf$shapeOf$halfOf" = "1111110" ]; then
            report_pass "$name (struct return -- step, lookupAge, halves, qr, segOf and shapeOf return their structs, halfOf none)"
        else
            report_fail "$name" "struct workers step=$step lookupAge=$lookupAge halves=$halves qr=$qr segOf=$segOf shapeOf=$shapeOf halfOf=$halfOf in $dump"
        fi
    fi

    # Test91IntConstFold: `Int` literals and casts fold like `Int64`, and a
    # large `Integer` literal lends its value to the cast reading it, so
    # the literal-only half of each line builds no `Integer` at run time.
    # `--directive noconstfold` fails this.
    if [ "$name" = "Test91IntConstFold" ]; then
        leftovers="$(grep -cE 'mkIntegerLiteral\("(18446744073709551621|9223372036854775807|4611686018427387904)"\)' "$TMP/${name}_rc2.c" || true)"
        if [ "$leftovers" = "0" ]; then
            report_pass "$name (Int constant folding -- no literal Integer left behind a folded cast)"
        else
            report_fail "$name" "$leftovers Integer literal(s) still built for a foldable Int cast in $TMP/${name}_rc2.c"
        fi
    fi

    # Test92ArityRaise: `sumPos` returns a closure waiting for the world;
    # raised (doc/world-arity-raising.md), its recursive call is a direct
    # call, so its raised version gets a struct-returning worker with a
    # native `Int` (`Ret1:1=Int`) and no `apply` of its own. `--directive
    # noarityraise` fails this.
    if [ "$name" = "Test92ArityRaise" ]; then
        dump="$TMP/${name}_rc2.rcexpr"
        raised="$(grep -c '^def {idris2rc2_worker_rc2_raised_Main_sumPos_[0-9]*:[0-9]*} .* ret= Ret1:1=Int ' "$dump" || true)"
        applies="$(awk '/^def /{d=$2} /^ *apply /{if (d ~ /rc2_raised_Main_sumPos/) n++} END{print n+0}' "$dump")"
        if [ "$raised" = "1" ] && [ "$applies" = "0" ]; then
            report_pass "$name (arity raising -- sumPos's raised version returns Ret1:1=Int, no apply)"
        else
            report_fail "$name" "raised struct worker=$raised, applies in it=$applies in $dump"
        fi
    fi

    # Test93ApplyFold: LateInline splices the non-`%inline` `bind` into
    # `run` after RC annotation, leaving closures built and applied at
    # once; the post-RC fold (doc/world-arity-raising.md's "Post-RC
    # fold") turns both into calls, so nothing in `run` applies a
    # closure. `--directive noapplyfold` fails this.
    if [ "$name" = "Test93ApplyFold" ]; then
        applies="$(awk '/^def /{d=$2} /^ *apply /{if (d ~ /Main_run|Main\.run|Main\.\{run/) n++} END{print n+0}' "$TMP/${name}_rc2.rcexpr")"
        if [ "$applies" = "0" ]; then
            report_pass "$name (post-RC fold -- no apply left in run)"
        else
            report_fail "$name" "$applies apply(s) left in run in $TMP/${name}_rc2.rcexpr"
        fi
    fi

    run_t0="$(date +%s.%N)"
    actual="$("$TMP/${name}_rc2" 2>&1)"
    run_time="$(elapsed "$run_t0" "$(date +%s.%N)")"

    if is_in "$name" "$NO_REFC_DIFF_TESTS"; then
        if [ -f "$RC2_DIR/tests/$name/$name.expected" ]; then
            expected="$(cat "$RC2_DIR/tests/$name/$name.expected")"
            if [ "$actual" = "$expected" ]; then
                report_pass "$name ($(timing_note "$compile_time" "$run_time"); vs. saved .expected, refc diff skipped by design -- see NO_REFC_DIFF_TESTS above)"
            else
                report_fail "$name" "mismatch against saved .expected (compile ${compile_time}s, run ${run_time}s)"
            fi
        else
            report_fail "$name" "no saved .expected, and refc diff is skipped by design for this test -- see NO_REFC_DIFF_TESTS above"
        fi
    else
        expected_file="$RC2_DIR/tests/$name/$name.expected"
        if [ "$REGEN_EXPECTED" -eq 1 ]; then
            env "${companion_env[@]}" idris2 --cg refc -p network -p linear -p rc2base \
                "$RC2_DIR/tests/$name/$name.idr" -o "$TMP/${name}_refc" \
                > "$TMP/${name}_refc_compile.log" 2>&1
            if [ ! -x "$TMP/${name}_refc" ]; then
                report_fail "$name" "refc compile error, see $TMP/${name}_refc_compile.log"
                continue
            fi
            "$TMP/${name}_refc" > "$expected_file" 2>&1
        fi
        if [ ! -f "$expected_file" ]; then
            report_fail "$name" "no saved .expected -- run with --regen-expected first"
            continue
        fi
        expected="$(cat "$expected_file")"
        if [ "$actual" = "$expected" ]; then
            report_pass "$name (compile ${compile_time}s, run ${run_time}s)"
        else
            diff <(echo "$expected") <(echo "$actual") > "$TMP/${name}.diff"
            report_fail "$name" "output mismatch (compile ${compile_time}s, run ${run_time}s), see $TMP/${name}.diff"
        fi
    fi
done

if [ "$DO_VALGRIND" -eq 1 ] && ! command -v valgrind >/dev/null 2>&1; then
    echo
    report_fail "valgrind" "not on PATH -- run inside nix-shell -p ... valgrind, or pass --no-valgrind"
elif [ "$DO_VALGRIND" -eq 1 ]; then
    echo
    echo "=== valgrind (leak-sensitive tests) ==="

    # Each valgrind run is its own single-threaded process operating on
    # its own binary/log file, so the leak-sensitive subset (or the
    # full suite under --valgrind-all) parallelizes cleanly. Capped at
    # nproc/2 rather than nproc: valgrind's own per-process memory
    # overhead (multiple times the target binary's) means running one
    # per core risks swapping on a memory-constrained machine, which
    # would erase the wall-clock win this is for. Override via
    # VALGRIND_JOBS= if a given machine can take more (or needs less).
    valgrind_jobs="${VALGRIND_JOBS:-$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))}"

    valgrind_names=()
    for name in $ALL_TESTS; do
        if [ "$VALGRIND_ALL" -eq 0 ] && ! is_in "$name" "$LEAK_SENSITIVE_TESTS"; then
            continue
        fi
        [ -x "$TMP/${name}_rc2" ] || continue
        valgrind_names+=("$name")
    done

    valgrind_t0="$(date +%s.%N)"
    running=0
    for name in "${valgrind_names[@]}"; do
        valgrind --leak-check=full --errors-for-leak-kinds=none --error-exitcode=1 "$TMP/${name}_rc2" \
            > "$TMP/${name}_valgrind.log" 2>&1 &
        running=$((running + 1))
        if [ "$running" -ge "$valgrind_jobs" ]; then
            wait -n
            running=$((running - 1))
        fi
    done
    wait
    valgrind_time="$(elapsed "$valgrind_t0" "$(date +%s.%N)")"

    # Reporting stays a separate, sequential pass over valgrind_names
    # (not folded into the launch loop above) so PASS/KNOWN/FAIL lines
    # print in the same deterministic $ALL_TESTS order regardless of
    # which background job happened to finish first.
    # A log with no `ERROR SUMMARY` means valgrind never ran the program
    # to the end (a missing shared library, a crash of its own); a
    # non-zero one is an invalid read/write or free, which a leak count
    # alone would never show.
    for name in "${valgrind_names[@]}"; do
        leaked="$(grep -oP 'definitely lost: \K[0-9,]+(?= bytes)' "$TMP/${name}_valgrind.log" | tr -d ',')"
        leaked="${leaked:-0}"
        expected_leak="${KNOWN_LEAK_BYTES[$name]:-0}"
        errors="$(grep -oP 'ERROR SUMMARY: \K[0-9,]+(?= errors)' "$TMP/${name}_valgrind.log" | tr -d ',')"
        if [ -z "$errors" ]; then
            report_fail "$name (valgrind)" "no ERROR SUMMARY, valgrind did not finish -- see $TMP/${name}_valgrind.log"
        elif [ "$errors" -ne 0 ]; then
            report_fail "$name (valgrind)" "$errors memory error(s) -- see $TMP/${name}_valgrind.log"
        elif [ "$leaked" -eq 0 ]; then
            report_pass "$name (valgrind, 0 bytes definitely lost)"
        elif [ "$leaked" -eq "$expected_leak" ]; then
            report_known "$name (valgrind)" "$leaked bytes definitely lost, matches recorded pre-existing leak"
        else
            report_fail "$name (valgrind)" "$leaked bytes definitely lost (expected 0 or the known $expected_leak) -- see $TMP/${name}_valgrind.log"
        fi
    done
    echo "(valgrind phase: ${valgrind_time}s wall, ${#valgrind_names[@]} tests, $valgrind_jobs parallel jobs)"
fi

echo
echo "== $pass passed, $known known (pre-existing, see KNOWN-BUGS.md), $fail failed =="
if [ "$fail" -gt 0 ] || [ "$refc_suite_status" -ne 0 ]; then
    [ "${#failed_names[@]}" -gt 0 ] && echo "Failed: ${failed_names[*]}"
    exit 1
fi
exit 0
