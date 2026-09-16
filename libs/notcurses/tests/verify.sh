#!/usr/bin/env bash
# One-shot build+link+run check for libs/notcurses. Cleans and
# rebuilds the C shim, type-checks the package against the plain Chez
# backend, installs it into a throwaway local prefix, builds
# tests/TestVersion.idr against idris2-rc-cg's own rc2 backend, and
# runs it. Sibling of libs/text-re2/tests/verify.sh -- see that
# script's header for the fuller rationale.
#
# Deliberately does NOT exercise `init`/`render`/input -- those need a
# real terminal, which this script assumes it does not have (CI/
# sandboxed use). See ../examples/README.md for the interactive
# programs that cover the rest of the package by hand.
#
# Usage: ./verify.sh
#
# Requires nix-shell on PATH (brings in idris2/gcc/gmp/pkg-config/
# notcurses) and rc2/build/exec/idris2-rc2 already built.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
IDRIS2RC2="$REPO_ROOT/rc2/build/exec/idris2-rc2"

fail() { echo "FAIL  $1"; exit 1; }

if [[ ! -x "$IDRIS2RC2" ]]; then
    fail "rc2/build/exec/idris2-rc2 not found -- build it first (see rc2/tests/verify.sh)"
fi

source "$REPO_ROOT/env.sh"

echo "=== Clean rebuild of support/c ==="
nix-shell -p gnumake gcc pkg-config notcurses --run \
    "make -C '$PKG_DIR/support/c' clean && make -C '$PKG_DIR/support/c'"

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && nix-shell -p idris2 gnumake gcc pkg-config notcurses --run 'idris2 --build notcurses.ipkg')

echo "=== Install into throwaway local prefix ==="
rm -rf "$PKG_DIR/.local-install"
IDRIS2_PREFIX="$PKG_DIR/.local-install" \
    nix-shell -p idris2 gnumake gcc pkg-config notcurses --run \
    "cd '$PKG_DIR' && idris2 --install notcurses.ipkg"

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/notcurses.ipkg" | tr -d ' ')"
INSTALLED_LIB="$PKG_DIR/.local-install/idris2-0.8.0/notcurses-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2notcurses.a" ]] || fail "postinstall didn't install libidris2rc2notcurses.a to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/nc_util.h" ]] || fail "postinstall didn't install nc_util.h to $INSTALLED_LIB"

echo "=== rc2 backend: build TestVersion (against the INSTALLED lib/) ==="
export IDRIS2_PACKAGE_PATH="${IDRIS2_PACKAGE_PATH:-}:$PKG_DIR/.local-install/idris2-0.8.0"
nix-shell -p gcc gmp pkg-config notcurses --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p notcurses -o TestVersion_verify TestVersion.idr"

echo "=== Run ==="
# No $INSTALLED_LIB here -- libidris2rc2notcurses is a static archive
# now, baked straight into the executable, nothing to find at runtime.
NOTCURSES_LIBDIR="$(nix-shell -p notcurses pkg-config --run 'pkg-config --variable=libdir notcurses-core')"
export LD_LIBRARY_PATH="$REPO_ROOT/install/idris2-0.8.0/support/rc2:$NOTCURSES_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
OUT="$("$TESTS_DIR/build/exec/TestVersion_verify")"
echo "$OUT"

if [[ "$OUT" == PASS:* ]]; then
    echo "PASS  TestVersion"
else
    fail "TestVersion -- unexpected output"
fi
