#!/usr/bin/env bash
# Runs every ported RefC regression test (originally from
# idris2-src/tests/refc/*) against the rc2 backend and diffs the output
# against the (mostly unmodified) upstream `expected` files. See
# rc2/tests/refc-suite/README.md for what was ported, skipped, and why.
#
# Usage: source ../../../env.sh first, then run this from inside a
# nix-shell providing gcc/gmp/pkg-config (or wrap the whole thing, as the
# examples in README.md do).
set -u

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDRIS2RC2="${IDRIS2RC2:-/home/hhiroki/projects/idris2-rc-cg/rc2/build/exec/idris2-rc2}"

pass=0
fail=0
failed_names=()

for dir in "$SUITE_DIR"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/expected" ] || continue

    idr_file="$(find "$dir" -maxdepth 1 -name '*.idr' | head -n1)"
    if [ -z "$idr_file" ]; then
        echo "SKIP  $name (no .idr file)"
        continue
    fi

    exename="test"
    [ -f "$dir/exename" ] && exename="$(cat "$dir/exename")"

    pkg_flags=()
    if [ -f "$dir/pkgs" ]; then
        while read -r p; do
            [ -n "$p" ] && pkg_flags+=(-p "$p")
        done < "$dir/pkgs"
    fi

    (
        cd "$dir" || exit 1
        rm -rf build
        idr_basename="$(basename "$idr_file")"
        if ! "$IDRIS2RC2" --cg rc2 --directive dumprcexpr "${pkg_flags[@]}" "$idr_basename" -o "$exename" > compile.log 2>&1; then
            echo "FAIL  $name (compile error, see $dir/compile.log)"
            exit 1
        fi

        actual_out=""
        if [ -f runs ]; then
            while read -r run_args; do
                # shellcheck disable=SC2086
                out="$(./build/exec/"$exename" $run_args 2>&1)"
                actual_out="${actual_out}${out}
"
            done < runs
        else
            actual_out="$(./build/exec/"$exename" 2>&1)
"
        fi
        # Optional post-run hook: some upstream tests inspect a file the
        # program wrote (e.g. buffer's `base64 testWrite.buf`) rather than
        # just diffing stdout. If present, its stdout is appended to the
        # captured output before diffing against `expected`.
        if [ -f postrun.sh ]; then
            post_out="$(bash postrun.sh 2>&1)"
            actual_out="${actual_out}${post_out}
"
        fi
        printf '%s' "$actual_out" > actual.out

        if diff -u expected actual.out > diff.log 2>&1; then
            echo "PASS  $name"
            rm -f compile.log diff.log actual.out
            exit 0
        else
            echo "FAIL  $name (output mismatch, see $dir/diff.log)"
            exit 1
        fi
    )
    if [ $? -eq 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_names+=("$name")
    fi
done

echo
echo "== $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
    echo "Failed: ${failed_names[*]}"
    exit 1
fi
