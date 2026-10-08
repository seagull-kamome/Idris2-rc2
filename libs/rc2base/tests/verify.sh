#!/usr/bin/env bash
# One-shot correctness verification for libs/rc2base: cleans and
# rebuilds the C support library, type-checks the package against the
# plain Chez backend, installs it into the *same* shared install/
# prefix rc2 itself uses (never a separate throwaway prefix -- a
# second, parallel install of this same package was found to go stale
# independently of the shared one, since nothing ever re-syncs the
# two, and its own package resolution could end up picking either one
# depending on search-path order; installing to the one shared
# location rc2's own env.sh already defaults to removes that
# ambiguity entirely), then builds every test under tests/<TestName>/
# (one directory per test, holding <TestName>.idr and
# <TestName>.expected) against idris2-rc-cg's own rc2 backend, runs it
# and diffs its stdout against <TestName>.expected. The TESTS list
# below is explicit; the script fails if it and the tests/*/
# directories disagree. Small-scale sibling of
# rc2/tests/verify.sh -- see that script's own header for the fuller
# rationale this one deliberately doesn't repeat.
#
# Usage: ./verify.sh
#
# Requires gcc, gmp, pkg-config and make on PATH (the same way
# rc2/tests/verify.sh does -- idris2 itself is the self-built one,
# never nixpkgs', per AGENT.md's "Policy: don't use nixpkgs' idris2 for
# rc2 work") and rc2/build/exec/idris2-rc2 already built (see rc2/tests/verify.sh or
# rc2/README.md).

set -euo pipefail

# rc2's runtime does setlocale(LC_ALL, "") in idris2rc2_rtInit, so a
# compiled test's behaviour follows this shell's locale. Pin it:
# TestRegexPOSIX asserts codepoint-wise `.` / [[:alpha:]] matching,
# which needs a UTF-8 LC_CTYPE (rc2/doc/runtime-lifecycle.md).
export LC_ALL=C.UTF-8

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
IDRIS2RC2="$REPO_ROOT/rc2/build/exec/idris2-rc2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL  $1"; exit 1; }

if [[ ! -x "$IDRIS2RC2" ]]; then
    fail "rc2/build/exec/idris2-rc2 not found -- build it first (see rc2/tests/verify.sh)"
fi

source "$REPO_ROOT/env.sh"

# name|extra -p packages (rc2base is always passed)|what the test covers
TESTS=(
    "TestText||Data.String.RC2/Text basics"
    "TestTextTree|contrib|Data.Text, the finger-tree rope"
    "TestConcurrency||fork + System.Concurrency.RC2's Mutex/Condition"
    "TestXoroshiro128PlusPlus||System.Random.Xoroshiro128PlusPlus"
    "TestBufferRC2||Data.Buffer.RC2's %foreign_impl patches"
    "TestDoubleRC2||Data.Double.RC2's %foreign_impl patches"
    "TestXoroshiro64StarStar||System.Random.Xoroshiro64StarStar"
    "TestStringFFI||Data.String.FFI's ptrToString"
    "TestPtrRC2||System.FFI.C.Ptr's raw fetch/store"
    "TestSizeofRC2||System.FFI.C.Sizeof's Sizeof instances"
    "TestArrayRC2||System.FFI.C.Array's CArray"
    "TestIntegerGMP||Data.Integer.GMP's direct GMP bindings"
    "TestHTTPServer|network contrib|Network.HTTP.Server: cross-thread respond + stop"
    "TestRegexPOSIX||Text.Regex.POSIX: libc <regex.h> bindings"
    "TestURL||Network.URL: parse/build + percent codec"
    "TestStringRC2||Data.String.RC2: unsafeStringByteSlice / byteLength"
    "TestMVar||Control.Concurrent.MVar: Mutex/Condition-backed MVar"
    "TestDoubleConvert||Data.Double.Convert: Eisel-Lemire/Grisu2 fast path"
    "TestRcexprParser|contrib|Language.RCExpr.{AST,Lexer,Parser}: dumprcexpr grammar edge cases"
    "TestIORefRC2||Data.IORef.RC2: casIORef success/failure/retry loop"
    "TestMultiThreadRC2||System.GC.RC2: the switch to atomic reference counting"
)

echo "=== Check TESTS against the tests/*/ directories ==="
# Every tests/<T>/ must be listed and have <T>.idr + <T>.expected, and
# every listed test must have its directory.
listed=()
for entry in "${TESTS[@]}"; do listed+=("${entry%%|*}"); done
for d in "$TESTS_DIR"/*/; do
    t="$(basename "$d")"
    [[ "$t" == build ]] && continue
    found=0
    for l in "${listed[@]}"; do [[ "$l" == "$t" ]] && found=1; done
    [[ $found -eq 1 ]] || fail "tests/$t/ is not in the TESTS list"
done
for t in "${listed[@]}"; do
    [[ -d "$TESTS_DIR/$t" ]] || fail "TESTS lists $t but tests/$t/ does not exist"
    [[ -f "$TESTS_DIR/$t/$t.idr" ]] || fail "tests/$t/$t.idr missing"
    [[ -f "$TESTS_DIR/$t/$t.expected" ]] || fail "tests/$t/$t.expected missing"
done

echo "=== Clean rebuild of support/c ==="
( make -C "$PKG_DIR/support/c" clean && make -C "$PKG_DIR/support/c" )

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && idris2 --build rc2base.ipkg)

echo "=== Install into the shared install/ prefix ==="
( cd "$PKG_DIR" && idris2 --install rc2base.ipkg )

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/rc2base.ipkg" | tr -d ' ')"
INSTALLED_LIB="$REPO_ROOT/install/idris2-0.8.0/rc2base-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2base.a" ]] || fail "postinstall didn't install libidris2rc2base.a to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/idris2rc2_rc2base_text_util.h" ]] || fail "postinstall didn't install idris2rc2_rc2base_text_util.h to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/idris2rc2_rc2base_concurrency_util.h" ]] || fail "postinstall didn't install idris2rc2_rc2base_concurrency_util.h to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/idris2rc2_rc2base_ptr_util.h" ]] || fail "postinstall didn't install idris2rc2_rc2base_ptr_util.h to $INSTALLED_LIB"

# No IDRIS2_PACKAGE_PATH export needed: idris2 already searches its
# own installation prefix (install/, the same one just installed into
# above) by default. No IDRIS2_CFLAGS/IDRIS2_LDFLAGS needed either:
# Compiler.RC2.CC's own depPkgLibDirs already adds -I<...>/lib and
# -L<...>/lib for every -p'd package's own installed lib/ (here,
# $INSTALLED_LIB) automatically -- see libs/rc2base/README.md's
# "Native library install location". idris2-rc2 always writes its -o
# output under <cwd>/build/exec/, so each test is built from inside its
# own directory (tests/<T>/build/ is git-ignored). No extra
# LD_LIBRARY_PATH is needed to run: libidris2_support.so already came
# from env.sh's own LD_LIBRARY_PATH, sourced above.
for entry in "${TESTS[@]}"; do
    IFS='|' read -r t extra desc <<< "$entry"
    pflags=(-p rc2base)
    for p in $extra; do pflags+=(-p "$p"); done

    echo "=== rc2 backend: build $t ($desc) ==="
    ( cd "$TESTS_DIR/$t" && ulimit -v 12000000 && timeout 600 \
        "$IDRIS2RC2" --cg rc2 "${pflags[@]}" -o "${t}_verify" "$t.idr" )

    echo "=== Run and diff against $t.expected ==="
    rc=0
    ( ulimit -v 4000000; timeout 20 "$TESTS_DIR/$t/build/exec/${t}_verify" ) > "$TMP/actual.out" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        cat "$TMP/actual.out"
        fail "$t -- exited with status $rc (124 = 20s timeout)"
    fi

    if diff -u "$TESTS_DIR/$t/$t.expected" "$TMP/actual.out"; then
        echo "PASS  $t"
    else
        fail "$t -- output mismatch (see diff above)"
    fi
done
