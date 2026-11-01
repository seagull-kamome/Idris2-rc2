#!/usr/bin/env bash
# Builds the compiler with rc2 itself and checks the result; see doc/self-hosting.md.
#
# Usage: ./selfhost.sh [stage1|libs|api|fixed|diff|all]
#
#   stage1  Chez builds and installs idris2-rc2 and the rc2 package (rc2.ipkg;
#           this writes rc2/build and the rc2 package in install/), then rc2 builds
#           idris2-rc2-norepl (rc2-norepl.ipkg): about 10 minutes, the C compiler
#           takes most of it.
#   libs    stage1 builds prelude, base, linear, network, contrib and test of
#           idris2-src/libs.
#   api     stage1 type-checks the compiler's API package (idris2api.ipkg).
#   fixed   stage1 builds idris2-rc2-norepl again; its C must equal the C of stage1.
#   diff    compiles every program of rc2/tests with the Chez-built idris2-rc2 and
#           with stage1 and compares the C: any difference that is not only the
#           notation of a float literal is a failure (doc/self-hosting.md, 9).
#   all     stage1, libs, api, fixed and diff, in that order.
#
# Except for what stage1 writes (see above), everything is built under
# rc2/build/selfhost (git-ignored).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(dirname "$HERE")"
REPO_ROOT="$(dirname "$RC2_DIR")"
SRC="$REPO_ROOT/idris2-src"
WORK="$RC2_DIR/build/selfhost"
LIBS="prelude base linear network contrib test"

source "$REPO_ROOT/env.sh"
mkdir -p "$WORK"

fail() { echo "FAIL  $1"; exit 1; }

ttc_path() {
    local p="" l
    for l in $LIBS; do p="$p$WORK/libs/$l/build/ttc:"; done
    echo "$p"
}

stage1() {
    echo "=== stage1: Chez builds idris2-rc2, rc2 builds idris2-rc2-norepl ==="
    ( cd "$RC2_DIR" && idris2 --build rc2.ipkg && idris2 --install rc2.ipkg ) || fail "idris2-rc2 (Chez)"
    ( cd "$RC2_DIR" && build/exec/idris2-rc2 --cg rc2 --build rc2-norepl.ipkg ) || fail "idris2-rc2-norepl (rc2)"
    cp "$RC2_DIR/build/exec/idris2-rc2-norepl" "$WORK/stage1"
    cp "$RC2_DIR/build/exec/idris2-rc2-norepl.c" "$WORK/stage1.c"
    "$WORK/stage1" --version
    echo "PASS  stage1"
}

libs() {
    [[ -x "$WORK/stage1" ]] || fail "run stage1 first"
    echo "=== libs: stage1 builds the libraries of idris2-src/libs ==="
    rm -rf "$WORK/libs"
    cp -r "$SRC/libs" "$WORK/libs"
    find "$WORK/libs" -name build -prune -exec rm -rf {} +
    local l
    for l in $LIBS; do
        ( cd "$WORK/libs/$l" && IDRIS2_PATH="$(ttc_path)" "$WORK/stage1" --build "$l.ipkg" ) > "$WORK/libs-$l.log" 2>&1 \
            || { tail -20 "$WORK/libs-$l.log"; fail "$l"; }
        echo "PASS  $l"
    done
}

api() {
    [[ -x "$WORK/stage1" ]] || fail "run stage1 first"
    [[ -d "$WORK/libs/prelude/build/ttc" && -d "$WORK/libs/test/build/ttc" ]] || fail "run libs first"
    echo "=== api: stage1 type-checks idris2api.ipkg ==="
    rm -rf "$WORK/api"
    mkdir -p "$WORK/api"
    cp -r "$SRC/src" "$WORK/api/src"
    rm -rf "$WORK/api/src/build"
    cp "$SRC/idris2api.ipkg" "$WORK/api/"
    ( cd "$WORK/api" && IDRIS2_PATH="$(ttc_path)" "$WORK/stage1" --typecheck idris2api.ipkg ) > "$WORK/api.log" 2>&1 \
        || { tail -20 "$WORK/api.log"; fail "idris2api"; }
    echo "PASS  idris2api"
}

fixed() {
    [[ -x "$WORK/stage1" && -f "$WORK/stage1.c" ]] || fail "run stage1 first"
    echo "=== fixed: stage1 builds idris2-rc2-norepl again ==="
    rm -rf "$WORK/stage2"
    mkdir -p "$WORK/stage2"
    cp -r "$RC2_DIR/src_norepl" "$RC2_DIR/rc2-norepl.ipkg" "$WORK/stage2/"
    ( cd "$WORK/stage2" && "$WORK/stage1" --cg rc2 --build rc2-norepl.ipkg ) > "$WORK/stage2.log" 2>&1 \
        || { tail -20 "$WORK/stage2.log"; fail "stage2"; }
    cmp -s "$WORK/stage2/build/exec/idris2-rc2-norepl.c" "$WORK/stage1.c" || fail "the C of stage2 differs from the C of stage1"
    echo "PASS  fixed point: stage2 and stage1 are the same C"
}

diffc() {
    [[ -x "$WORK/stage1" && -x "$RC2_DIR/build/exec/idris2-rc2" ]] || fail "run stage1 first"
    echo "=== diff: the C of rc2/tests with idris2-rc2 (Chez) and with stage1 (rc2) ==="
    local out="$WORK/diff" t n=0 same=0 notation=0 bad=0
    local flags="-p contrib -p network -p linear -p rc2base"
    rm -rf "$out"
    mkdir -p "$out"
    cd "$RC2_DIR/tests"
    for d in Test*/; do
        t="${d%/}"
        [[ -f "$t/$t.idr" ]] || continue
        n=$((n + 1))
        rm -f build/exec/dfa_* build/exec/dfb_*
        "$RC2_DIR/build/exec/idris2-rc2" --cg rc2 $flags "$t/$t.idr" -o "dfa_$t" > "$out/$t.a.log" 2>&1 || true
        "$WORK/stage1" --cg rc2 $flags "$t/$t.idr" -o "dfb_$t" > "$out/$t.b.log" 2>&1 || true
        if [[ ! -f "build/exec/dfa_$t.c" || ! -f "build/exec/dfb_$t.c" ]]; then
            echo "NOC   $t"
            bad=$((bad + 1))
        elif cmp -s "build/exec/dfa_$t.c" "build/exec/dfb_$t.c"; then
            same=$((same + 1))
        else
            diff "build/exec/dfa_$t.c" "build/exec/dfb_$t.c" > "$out/$t.diff" || true
            if grep '^[<>]' "$out/$t.diff" | grep -v -E 'Double|[0-9]e-?[0-9]|[0-9]\.[0-9]' > /dev/null; then
                echo "DIFF  $t ($(grep -c '^[<>]' "$out/$t.diff") lines, see $out/$t.diff)"
                bad=$((bad + 1))
            else
                notation=$((notation + 1))
            fi
        fi
        rm -f build/exec/dfa_* build/exec/dfb_*
    done
    echo "$n programs: $same identical, $notation differ only in float notation, $bad differ"
    [[ $bad -eq 0 ]] || fail "the rc2-built compiler gives other C than the Chez-built one"
    echo "PASS  diff"
}

case "${1:-all}" in
    stage1) stage1 ;;
    libs) libs ;;
    api) api ;;
    fixed) fixed ;;
    diff) diffc ;;
    all) stage1; libs; api; fixed; diffc ;;
    *) echo "usage: $0 [stage1|libs|api|fixed|diff|all]"; exit 2 ;;
esac
