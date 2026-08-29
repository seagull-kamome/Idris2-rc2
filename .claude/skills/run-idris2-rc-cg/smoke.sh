#!/usr/bin/env bash
# Driver for the run-idris2-rc-cg skill.
# Builds rc2 (if not already built), compiles a small smoke-test Idris2
# program through the rc2 backend, runs it, and checks the output.
#
# Usage: ./smoke.sh [--build] [--full-tests]
#   --build       run `idris2 --build`/`--install` first (skip if you
#                 already have rc2/build/exec/idris2-rc2)
#   --full-tests  additionally run rc2/tests/verify.sh (slow, ~10 min,
#                 needs valgrind)
set -euo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$UNIT_DIR"

DO_BUILD=0
DO_FULL=0
for arg in "$@"; do
  case "$arg" in
    --build) DO_BUILD=1 ;;
    --full-tests) DO_FULL=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -f env.sh ]; then
  echo "env.sh missing -- run ./gen-env.sh first (needs nix-shell -p idris2)" >&2
  exit 1
fi
source env.sh

if [ "$DO_BUILD" = 1 ] || [ ! -x rc2/build/exec/idris2-rc2 ]; then
  echo "== building rc2 =="
  export IDRIS2_PREFIX="$(pwd)/install"
  (cd rc2 && nix-shell -p idris2 gcc gmp pkg-config --run \
    'idris2 --build rc2.ipkg && idris2 --install rc2.ipkg')
fi

echo "== smoke-compiling a test program through rc2 =="
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/Hello.idr" <<'EOF'
module Main

main : IO ()
main = do
  putStrLn "hello from rc2"
  let xs = map (*2) [1,2,3,4,5]
  printLn (sum xs)
EOF

nix-shell -p gcc gmp pkg-config --run \
  "cd '$WORKDIR' && '$UNIT_DIR/rc2/build/exec/idris2-rc2' --cg rc2 Hello.idr -o hello"

OUT="$("$WORKDIR/build/exec/hello")"
echo "$OUT"

EXPECTED=$'hello from rc2\n30'
if [ "$OUT" != "$EXPECTED" ]; then
  echo "SMOKE TEST FAILED: unexpected output" >&2
  exit 1
fi
echo "== smoke test OK =="

if [ "$DO_FULL" = 1 ]; then
  echo "== running full verify.sh (refc-suite + smoke + valgrind) =="
  (cd rc2/tests && source ../../env.sh && \
    nix-shell -p idris2 gcc gmp pkg-config valgrind --run './verify.sh')
fi
