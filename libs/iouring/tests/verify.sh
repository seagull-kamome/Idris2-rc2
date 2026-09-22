#!/usr/bin/env bash
# One-shot build+link+run check for libs/iouring. Cleans and rebuilds
# the C shim, type-checks the package against the plain Chez backend,
# installs it into a throwaway local prefix, builds each TestX.idr
# against idris2-rc-cg's own rc2 backend, and runs it. Sibling of
# libs/notcurses/tests/verify.sh -- see that script's header for the
# fuller rationale. Unlike notcurses, every test here is fully
# automated (file I/O and loopback TCP only, no TTY needed).
#
# Usage: ./verify.sh
#
# Requires nix-shell on PATH (brings in idris2/gcc/gmp/pkg-config/
# liburing) and rc2/build/exec/idris2-rc2 already built.

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
nix-shell -p gnumake gcc pkg-config liburing --run \
    "make -C '$PKG_DIR/support/c' clean && make -C '$PKG_DIR/support/c'"

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && nix-shell -p idris2 gnumake gcc pkg-config liburing --run 'idris2 --build iouring.ipkg')

echo "=== Install into throwaway local prefix ==="
rm -rf "$PKG_DIR/.local-install"
IDRIS2_PREFIX="$PKG_DIR/.local-install" \
    nix-shell -p idris2 gnumake gcc pkg-config liburing --run \
    "cd '$PKG_DIR' && idris2 --install iouring.ipkg"

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/iouring.ipkg" | tr -d ' ')"
INSTALLED_LIB="$PKG_DIR/.local-install/idris2-0.8.0/iouring-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2iouring.a" ]] || fail "postinstall didn't install libidris2rc2iouring.a to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/iouring_util.h" ]] || fail "postinstall didn't install iouring_util.h to $INSTALLED_LIB"

export IDRIS2_PACKAGE_PATH="${IDRIS2_PACKAGE_PATH:-}:$PKG_DIR/.local-install/idris2-0.8.0"

run_test() {
    local name="$1"
    echo "=== rc2 backend: build+run $name ==="
    nix-shell -p gcc gmp pkg-config liburing --run \
        "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p iouring -p network -o ${name}_verify ${name}.idr"
    local out
    out="$("$TESTS_DIR/build/exec/${name}_verify")"
    echo "$out"
    if [[ "$out" == PASS:* ]]; then
        echo "PASS  $name"
    else
        fail "$name -- unexpected output"
    fi
}

run_test TestNop
run_test TestFile
run_test TestSocket

echo "=== All iouring tests passed ==="
