#!/usr/bin/env bash
# One-shot correctness check for libs/text-re2: cleans and rebuilds the
# C++ shim, type-checks the package against the plain Chez backend,
# installs it into a throwaway local prefix, builds tests/TestRE2.idr
# against idris2-rc-cg's own rc2 backend, runs it, and diffs its stdout
# against tests/TestRE2.expected. Sibling of libs/rc2base/tests/verify.sh
# -- see that script's header for the fuller rationale.
#
# Usage: ./verify.sh
#
# Requires nix-shell on PATH (brings in idris2/gcc/g++/gmp/pkg-config/re2)
# and rc2/build/exec/idris2-rc2 already built.

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
nix-shell -p gnumake gcc gmp pkg-config re2 --run \
    "make -C '$PKG_DIR/support/c' clean && make -C '$PKG_DIR/support/c'"

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && nix-shell -p idris2 gnumake gcc gmp pkg-config re2 --run 'idris2 --build text-re2.ipkg')

echo "=== Install into throwaway local prefix ==="
rm -rf "$PKG_DIR/.local-install"
IDRIS2_PREFIX="$PKG_DIR/.local-install" \
    nix-shell -p idris2 gnumake gcc gmp pkg-config re2 --run \
    "cd '$PKG_DIR' && idris2 --install text-re2.ipkg"

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/text-re2.ipkg" | tr -d ' ')"
INSTALLED_LIB="$PKG_DIR/.local-install/idris2-0.8.0/text-re2-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2re2.so" ]] || fail "postinstall didn't install libidris2rc2re2.so to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/re2_util.h" ]] || fail "postinstall didn't install re2_util.h to $INSTALLED_LIB"

echo "=== rc2 backend: build TestRE2 (against the INSTALLED lib/) ==="
export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$PKG_DIR/.local-install/idris2-0.8.0"
export IDRIS2_CFLAGS="-I$INSTALLED_LIB"
export IDRIS2_LDFLAGS="-L$INSTALLED_LIB"
nix-shell -p gcc gmp pkg-config re2 --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p text-re2 -o TestRE2_verify TestRE2.idr"

echo "=== Run and diff stdout against TestRE2.expected ==="
# libidris2rc2re2.so is a shared object -- needed on LD_LIBRARY_PATH at
# run time, not just -L at link time.
export LD_LIBRARY_PATH="$INSTALLED_LIB:$REPO_ROOT/install/idris2-0.8.0/support/rc2${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# stdout only: RE2/abseil log to stderr unconditionally (see doc/regex.md).
"$TESTS_DIR/build/exec/TestRE2_verify" > "$TMP/actual.out" 2>/dev/null

if diff -u "$TESTS_DIR/TestRE2.expected" "$TMP/actual.out"; then
    echo "PASS  TestRE2"
else
    fail "TestRE2 -- output mismatch (see diff above)"
fi
