#!/usr/bin/env bash
# Builds and runs poolstress.c against the pool: as it ships, in check mode
# (IDRIS2RC2_POOL_CHECK) and under ThreadSanitizer. Usage: ./run.sh [cells per producer]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$HERE/../.." && pwd)"
SUP="$RC2_DIR/support/rc2"
OUT="${POOL_TEST_OUT:-$RC2_DIR/tests/build/pool}"
N="${1:-}"
NTSAN="${1:-100000}"
mkdir -p "$OUT"
status=0
run() { # run <name> <cflags...>
  local name=$1; shift
  if ! ${CC:-gcc} -std=gnu11 "$@" -pthread -I "$SUP" -o "$OUT/poolstress_$name" \
        "$HERE/poolstress.c" "$SUP/idris2rc2_pool.c" "$SUP/idris2rc2_util.c" 2> "$OUT/poolstress_$name.log"; then
    echo "FAIL  pool stress ($name): build, see $OUT/poolstress_$name.log"; status=1; return
  fi
  local n=$N; [ "$name" = tsan ] && n=$NTSAN
  if "$OUT/poolstress_$name" $n > "$OUT/poolstress_$name.out" 2>&1; then
    echo "PASS  pool stress ($name)"
  else
    echo "FAIL  pool stress ($name): see $OUT/poolstress_$name.out"; tail -n 5 "$OUT/poolstress_$name.out"; status=1
  fi
}
run plain -O2
run check -O1 -g -DIDRIS2RC2_POOL_CHECK
run tsan -O1 -g -fsanitize=thread
exit $status
