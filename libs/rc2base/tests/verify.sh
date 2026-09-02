#!/usr/bin/env bash
# One-shot correctness verification for libs/rc2base: cleans and
# rebuilds the C support library, type-checks the package against the
# plain Chez backend, installs it into a throwaway local prefix,
# builds tests/TestText.idr against idris2-rc-cg's own rc2 backend,
# runs it, and diffs its stdout against tests/TestText.expected.
# Small-scale sibling of rc2/tests/verify.sh -- see that script's own
# header for the fuller rationale this one deliberately doesn't repeat.
#
# Usage: ./verify.sh
#
# Requires nix-shell on PATH (used to bring in idris2/gcc/gmp/pkg-config
# the same way rc2/tests/verify.sh does) and rc2/build/exec/idris2-rc2
# already built (see rc2/tests/verify.sh or rc2/README.md).

set -euo pipefail

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

echo "=== Clean rebuild of support/c ==="
nix-shell -p gnumake gcc gmp pkg-config --run \
    "make -C '$PKG_DIR/support/c' clean && make -C '$PKG_DIR/support/c'"

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2base.ipkg')

echo "=== Install into throwaway local prefix ==="
rm -rf "$PKG_DIR/.local-install"
IDRIS2_PREFIX="$PKG_DIR/.local-install" \
    nix-shell -p idris2 gnumake gcc gmp pkg-config --run \
    "cd '$PKG_DIR' && idris2 --install rc2base.ipkg"

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/rc2base.ipkg" | tr -d ' ')"
INSTALLED_LIB="$PKG_DIR/.local-install/idris2-0.8.0/rc2base-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2base.a" ]] || fail "postinstall didn't install libidris2rc2base.a to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/text_util.h" ]] || fail "postinstall didn't install text_util.h to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/concurrency_util.h" ]] || fail "postinstall didn't install concurrency_util.h to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/ptr_util.h" ]] || fail "postinstall didn't install ptr_util.h to $INSTALLED_LIB"

echo "=== rc2 backend: build TestText (against the INSTALLED lib/, not support/c) ==="
export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$PKG_DIR/.local-install/idris2-0.8.0"
export IDRIS2_CFLAGS="-I$INSTALLED_LIB -I$REPO_ROOT/install/idris2-0.8.0/support"
export IDRIS2_LDFLAGS="-L$INSTALLED_LIB"
# idris2-rc2 always writes its -o output under <cwd>/build/exec/, so cd
# into tests/ first to get a predictable, self-contained output path.
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestText_idris2Text_verify TestText.idr"

echo "=== Run and diff against TestText.expected ==="
export LD_LIBRARY_PATH="$REPO_ROOT/install/idris2-0.8.0/support/rc2${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$TESTS_DIR/build/exec/TestText_idris2Text_verify" > "$TMP/actual.out" 2>&1

if diff -u "$TESTS_DIR/TestText.expected" "$TMP/actual.out"; then
    echo "PASS  TestText"
else
    fail "TestText -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestTextTree (Data.Text, the finger-tree rope) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -p contrib -o TestTextTree_verify TestTextTree.idr"

echo "=== Run and diff against TestTextTree.expected ==="
"$TESTS_DIR/build/exec/TestTextTree_verify" > "$TMP/actual2.out" 2>&1

if diff -u "$TESTS_DIR/TestTextTree.expected" "$TMP/actual2.out"; then
    echo "PASS  TestTextTree"
else
    fail "TestTextTree -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestConcurrency (fork + System.Concurrency.RC2's Mutex/Condition) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestConcurrency_verify TestConcurrency.idr"

echo "=== Run and diff against TestConcurrency.expected ==="
"$TESTS_DIR/build/exec/TestConcurrency_verify" > "$TMP/actual3.out" 2>&1

if diff -u "$TESTS_DIR/TestConcurrency.expected" "$TMP/actual3.out"; then
    echo "PASS  TestConcurrency"
else
    fail "TestConcurrency -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestXoroshiro128PlusPlus (System.Random.Xoroshiro128PlusPlus) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestXoroshiro128PlusPlus_verify TestXoroshiro128PlusPlus.idr"

echo "=== Run and diff against TestXoroshiro128PlusPlus.expected ==="
"$TESTS_DIR/build/exec/TestXoroshiro128PlusPlus_verify" > "$TMP/actual4.out" 2>&1

if diff -u "$TESTS_DIR/TestXoroshiro128PlusPlus.expected" "$TMP/actual4.out"; then
    echo "PASS  TestXoroshiro128PlusPlus"
else
    fail "TestXoroshiro128PlusPlus -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestBufferRC2 (Data.Buffer.RC2's %foreign_impl patches) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestBufferRC2_verify TestBufferRC2.idr"

echo "=== Run and diff against TestBufferRC2.expected ==="
"$TESTS_DIR/build/exec/TestBufferRC2_verify" > "$TMP/actual5.out" 2>&1

if diff -u "$TESTS_DIR/TestBufferRC2.expected" "$TMP/actual5.out"; then
    echo "PASS  TestBufferRC2"
else
    fail "TestBufferRC2 -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestDoubleRC2 (Data.Double.RC2's %foreign_impl patches) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestDoubleRC2_verify TestDoubleRC2.idr"

echo "=== Run and diff against TestDoubleRC2.expected ==="
"$TESTS_DIR/build/exec/TestDoubleRC2_verify" > "$TMP/actual6.out" 2>&1

if diff -u "$TESTS_DIR/TestDoubleRC2.expected" "$TMP/actual6.out"; then
    echo "PASS  TestDoubleRC2"
else
    fail "TestDoubleRC2 -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestXoroshiro64StarStar (System.Random.Xoroshiro64StarStar) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestXoroshiro64StarStar_verify TestXoroshiro64StarStar.idr"

echo "=== Run and diff against TestXoroshiro64StarStar.expected ==="
"$TESTS_DIR/build/exec/TestXoroshiro64StarStar_verify" > "$TMP/actual7.out" 2>&1

if diff -u "$TESTS_DIR/TestXoroshiro64StarStar.expected" "$TMP/actual7.out"; then
    echo "PASS  TestXoroshiro64StarStar"
else
    fail "TestXoroshiro64StarStar -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestStringFFI (Data.String.FFI's ptrToString) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestStringFFI_verify TestStringFFI.idr"

echo "=== Run and diff against TestStringFFI.expected ==="
"$TESTS_DIR/build/exec/TestStringFFI_verify" > "$TMP/actual8.out" 2>&1

if diff -u "$TESTS_DIR/TestStringFFI.expected" "$TMP/actual8.out"; then
    echo "PASS  TestStringFFI"
else
    fail "TestStringFFI -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestPtrRC2 (System.FFI.C.Ptr's raw fetch/store) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestPtrRC2_verify TestPtrRC2.idr"

echo "=== Run and diff against TestPtrRC2.expected ==="
"$TESTS_DIR/build/exec/TestPtrRC2_verify" > "$TMP/actual9.out" 2>&1

if diff -u "$TESTS_DIR/TestPtrRC2.expected" "$TMP/actual9.out"; then
    echo "PASS  TestPtrRC2"
else
    fail "TestPtrRC2 -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestSizeofRC2 (System.FFI.C.Sizeof's Sizeof instances) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestSizeofRC2_verify TestSizeofRC2.idr"

echo "=== Run and diff against TestSizeofRC2.expected ==="
"$TESTS_DIR/build/exec/TestSizeofRC2_verify" > "$TMP/actual10.out" 2>&1

if diff -u "$TESTS_DIR/TestSizeofRC2.expected" "$TMP/actual10.out"; then
    echo "PASS  TestSizeofRC2"
else
    fail "TestSizeofRC2 -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestArrayRC2 (System.FFI.C.Array's CArray) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestArrayRC2_verify TestArrayRC2.idr"

echo "=== Run and diff against TestArrayRC2.expected ==="
"$TESTS_DIR/build/exec/TestArrayRC2_verify" > "$TMP/actual11.out" 2>&1

if diff -u "$TESTS_DIR/TestArrayRC2.expected" "$TMP/actual11.out"; then
    echo "PASS  TestArrayRC2"
else
    fail "TestArrayRC2 -- output mismatch (see diff above)"
fi

echo "=== rc2 backend: build TestIntegerGMP (Data.Integer.GMP's direct GMP bindings) ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p rc2base -o TestIntegerGMP_verify TestIntegerGMP.idr"

echo "=== Run and diff against TestIntegerGMP.expected ==="
"$TESTS_DIR/build/exec/TestIntegerGMP_verify" > "$TMP/actual12.out" 2>&1

if diff -u "$TESTS_DIR/TestIntegerGMP.expected" "$TMP/actual12.out"; then
    echo "PASS  TestIntegerGMP"
else
    fail "TestIntegerGMP -- output mismatch (see diff above)"
fi
