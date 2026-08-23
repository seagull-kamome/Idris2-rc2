#!/usr/bin/env bash
# One-shot correctness verification for libs/idris2-Text: cleans and
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
(cd "$PKG_DIR" && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build idris2-Text.ipkg')

echo "=== Install into throwaway local prefix ==="
rm -rf "$PKG_DIR/.local-install"
IDRIS2_PREFIX="$PKG_DIR/.local-install" \
    nix-shell -p idris2 gmp pkg-config --run \
    "cd '$PKG_DIR' && idris2 --install idris2-Text.ipkg"

echo "=== rc2 backend: build TestText ==="
export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$PKG_DIR/.local-install/idris2-0.8.0"
export IDRIS2_CFLAGS="-I$PKG_DIR/support/c -I$REPO_ROOT/install/idris2-0.8.0/support"
export IDRIS2_LDFLAGS="-L$PKG_DIR/support/c"
# idris2-rc2 always writes its -o output under <cwd>/build/exec/, so cd
# into tests/ first to get a predictable, self-contained output path.
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TESTS_DIR' && '$IDRIS2RC2' --cg rc2 -p idris2-Text -o TestText_idris2Text_verify TestText.idr"

echo "=== Run and diff against TestText.expected ==="
export LD_LIBRARY_PATH="$REPO_ROOT/install/idris2-0.8.0/support/rc2${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$TESTS_DIR/build/exec/TestText_idris2Text_verify" > "$TMP/actual.out" 2>&1

if diff -u "$TESTS_DIR/TestText.expected" "$TMP/actual.out"; then
    echo "PASS  TestText"
else
    fail "TestText -- output mismatch (see diff above)"
fi
