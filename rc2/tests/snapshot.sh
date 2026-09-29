#!/usr/bin/env bash
# Checks that a refactoring left rc2's output unchanged.
#
#   ./snapshot.sh save DIR   copy the IR dump and generated C of every
#                            smoke test in build/ (left there by the
#                            last verify.sh run) into DIR
#   ./snapshot.sh diff DIR   compare build/ against DIR, byte for byte
#
# Usage: run verify.sh on the code before the change, `save`, change
# the code, run verify.sh again, `diff`. Any difference names the test
# and the file (*.rcexpr is the IR, *.c the C); `diff -u` on the two
# copies shows where. For a bigger program, compile it with
# `--directive dumprcexpr` before and after and `cmp` the two dumps
# (idris2-lsp is the largest, see rc2/BENCHMARKS.md).
#
# Not for a change meant to alter the output (a new optimization):
# there the diff is the thing to read, not to keep empty.

set -euo pipefail

BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build"
mode="${1:-}"; dir="${2:-}"
[ -n "$dir" ] || { echo "usage: $0 save|diff DIR" >&2; exit 2; }

case "$mode" in
    save)
        mkdir -p "$dir"
        n=0
        for f in "$BUILD"/*_rc2.rcexpr "$BUILD"/*_rc2.c; do
            [ -f "$f" ] || continue
            cp "$f" "$dir/"
            n=$((n + 1))
        done
        [ "$n" -gt 0 ] || { echo "nothing to save: run verify.sh first" >&2; exit 1; }
        echo "saved $n files to $dir"
        ;;
    diff)
        [ -d "$dir" ] || { echo "no such snapshot: $dir" >&2; exit 2; }
        same=0; changed=()
        for f in "$dir"/*; do
            b="$(basename "$f")"
            if [ -f "$BUILD/$b" ] && cmp -s "$f" "$BUILD/$b"; then
                same=$((same + 1))
            else
                changed+=("$b")
            fi
        done
        for f in "$BUILD"/*_rc2.rcexpr "$BUILD"/*_rc2.c; do
            [ -f "$f" ] && [ ! -f "$dir/$(basename "$f")" ] && changed+=("$(basename "$f") (not in snapshot)")
        done
        if [ "${#changed[@]}" -eq 0 ]; then
            echo "PASS  $same files identical"
        else
            echo "FAIL  ${#changed[@]} differ, $same identical"
            printf '  %s\n' "${changed[@]}"
            exit 1
        fi
        ;;
    *) echo "usage: $0 save|diff DIR" >&2; exit 2 ;;
esac
