#!/usr/bin/env bash
# Runs the smoke tests once per optimization stage with that stage
# switched off (`--directive no<stage>`, rc2/doc/directives.md), to find
# a pass another pass silently depends on: `noreuse` once broke most
# tests and nothing but a hand-passed directive would have shown it.
#
# Usage: ./nopass.sh [STAGE...]     (default: every stage rc2 lists as
#                                    disableable, read from RC2.idr)
#
# Run inside the same nix-shell as verify.sh. rc2 must already be built.
# Each run is `verify.sh --skip-build --no-valgrind --no-tsan
# --no-refc-suite --directive <stage>`; its full output goes to
# nopass-<stage>.log next to this script.
#
# A test whose `check.sh` asserts that the stage fired fails when the
# stage is off: that is the check working, not a bug. Anything else
# failing is: an output that differs, a compile error, an rcexpr-lint
# anomaly.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../src/Compiler/RC2/RC2.idr"

if [ $# -gt 0 ]; then
    stages=("$@")
else
    read -r -a stages < <(
        sed -n '/^disableableStageNames =/,/^$/p' "$SRC" | grep -o '"no[a-z]*"' | tr -d '"' | tr '\n' ' ')
fi
[ "${#stages[@]}" -gt 0 ] || { echo "no stages found in $SRC" >&2; exit 2; }

bad=0
for s in "${stages[@]}"; do
    log="$DIR/nopass-$s.log"
    if "$DIR/verify.sh" --skip-build --no-valgrind --no-tsan --no-refc-suite --directive "$s" > "$log" 2>&1; then
        echo "PASS  $s"
    else
        bad=$((bad + 1))
        echo "FAIL  $s: $(grep -c '^FAIL' "$log") failing, first: $(grep '^FAIL' "$log" | head -3 | cut -c1-100 | tr '\n' '|') (see $log)"
    fi
done
echo "== ${#stages[@]} stages, $bad with failures =="
[ "$bad" -eq 0 ]
