#!/usr/bin/env bash
# Driver for the run-idris2-rc-cg skill.
# Builds rc2 (if not already built), compiles a small smoke-test Idris2
# program through the rc2 backend, runs it, and checks the output.
#
# Must be run from inside a nix-shell (or equivalent PATH setup)
# providing gcc, gmp and pkg-config -- add valgrind too if passing
# --full-tests. Building rc2 (no existing rc2/build/exec/idris2-rc2
# yet, or --build) also needs idris2, but that should already be on
# PATH via `source env.sh` below (the self-built one) -- nixpkgs' own
# idris2 is bootstrap-only per project policy, so don't add it to the
# -p list unless you specifically lack a self-built one. E.g.:
#   nix-shell -p gcc gmp pkg-config valgrind --run './smoke.sh'
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
  if ! command -v idris2 > /dev/null 2>&1; then
    echo "error: no 'idris2' on PATH -- this normally comes from the self-built one via 'source env.sh'; if you don't have one yet, nixpkgs' idris2 is bootstrap-only per project policy (nix-shell -p idris2 gcc gmp pkg-config --run './smoke.sh')" >&2
    exit 1
  fi
  echo "== building rc2 =="
  export IDRIS2_PREFIX="$(pwd)/install"
  (cd rc2 && idris2 --build rc2.ipkg && idris2 --install rc2.ipkg)
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

(cd "$WORKDIR" && "$UNIT_DIR/rc2/build/exec/idris2-rc2" --cg rc2 Hello.idr -o hello)

OUT="$("$WORKDIR/build/exec/hello")"
echo "$OUT"

EXPECTED=$'hello from rc2\n30'
if [ "$OUT" != "$EXPECTED" ]; then
  echo "SMOKE TEST FAILED: unexpected output" >&2
  exit 1
fi
echo "== smoke test OK =="

if [ "$DO_FULL" = 1 ]; then
  if ! command -v valgrind > /dev/null 2>&1; then
    echo "error: --full-tests needs 'valgrind' on PATH too -- run this script from inside e.g. nix-shell -p gcc gmp pkg-config valgrind --run './smoke.sh --full-tests'" >&2
    exit 1
  fi
  echo "== running full verify.sh (refc-suite + smoke + valgrind) =="
  (cd rc2/tests && ./verify.sh)
fi
