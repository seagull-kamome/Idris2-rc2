#!/usr/bin/env bash
# One-shot correctness check for libs/text-re2: cleans and rebuilds the
# C++ shim, type-checks the package against the plain Chez backend,
# installs it into the *same* shared install/ prefix rc2 itself uses
# (never a separate throwaway prefix -- a second, parallel install of
# this same package was found to go stale independently of the shared
# one, since nothing ever re-syncs the two; installing to the one
# shared location rc2's own env.sh already defaults to removes that
# ambiguity entirely), builds tests/TestRE2.idr against idris2-rc-cg's
# own rc2 backend, runs it, and diffs its stdout against
# tests/TestRE2.expected. Sibling of libs/rc2base/tests/verify.sh --
# see that script's header for the fuller rationale.
#
# Usage: ./verify.sh
#
# Requires gcc, g++, gmp, pkg-config and re2 (headers and libraries)
# on the build environment's PATH or compiler flags -- no nix-shell is
# used. idris2 itself is the self-built one, never nixpkgs', per
# AGENT.md's "Policy: don't use nixpkgs' idris2 for rc2 work", and
# rc2/build/exec/idris2-rc2 must already be built.

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
( make -C "$PKG_DIR/support/c" clean && make -C "$PKG_DIR/support/c" )

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && idris2 --build text-re2.ipkg)

echo "=== Install into the shared install/ prefix ==="
( cd "$PKG_DIR" && idris2 --install text-re2.ipkg )

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/text-re2.ipkg" | tr -d ' ')"
INSTALLED_LIB="$REPO_ROOT/install/idris2-0.8.0/text-re2-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2re2.so" ]] || fail "postinstall didn't install libidris2rc2re2.so to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/idris2rc2_text_re2_re2_util.h" ]] || fail "postinstall didn't install idris2rc2_text_re2_re2_util.h to $INSTALLED_LIB"

echo "=== rc2 backend: build TestRE2 (against the INSTALLED lib/) ==="
# No IDRIS2_PACKAGE_PATH export needed: idris2 already searches its
# own installation prefix (install/, the same one just installed into
# above) by default. No IDRIS2_CFLAGS/IDRIS2_LDFLAGS needed either:
# Compiler.RC2.CC's own
# depPkgLibDirs already adds -I<...>/lib and -L<...>/lib for every
# -p'd package's own installed lib/ (here, $INSTALLED_LIB) automatically
# -- see libs/rc2base/README.md's "Native library install location".
( cd "$TESTS_DIR" && "$IDRIS2RC2" --cg rc2 -p rc2base -p text-re2 -o TestRE2_verify TestRE2.idr )

echo "=== Run and diff stdout against TestRE2.expected ==="
# libidris2rc2re2.so is a shared object -- needed on LD_LIBRARY_PATH at
# run time, not just -L at link time (depPkgLibDirs only ever affects
# the compiler's own -I/-L, never the dynamic linker's runtime search
# path). support/rc2 has no .so of its own to add here.
export LD_LIBRARY_PATH="$INSTALLED_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# stdout only: RE2/abseil log to stderr unconditionally (see doc/regex.md).
"$TESTS_DIR/build/exec/TestRE2_verify" > "$TMP/actual.out" 2>/dev/null

if diff -u "$TESTS_DIR/TestRE2.expected" "$TMP/actual.out"; then
    echo "PASS  TestRE2"
else
    fail "TestRE2 -- output mismatch (see diff above)"
fi
