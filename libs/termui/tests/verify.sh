#!/usr/bin/env bash
# One-shot verification for libs/termui: type-checks the package, installs
# it into the shared install/ prefix, then builds every tests/<T>/<T>.idr
# with the rc2 backend, runs it and diffs stdout against <T>.expected.
# The TESTS list is explicit; the script fails if it and tests/*/ disagree.
# Same layout as libs/rc2base/tests/verify.sh, see its header for the rationale.
#
# Usage: ./verify.sh
#
# Requires rc2/build/exec/idris2-rc2 already built.

set -euo pipefail

export LC_ALL=C.UTF-8

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
IDRIS2RC2="$REPO_ROOT/rc2/build/exec/idris2-rc2"
mkdir -p "$TESTS_DIR/build"
TMP="$(mktemp -d -p "$TESTS_DIR/build")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL  $1"; exit 1; }

[[ -x "$IDRIS2RC2" ]] || fail "rc2/build/exec/idris2-rc2 not found -- build it first (see rc2/tests/verify.sh)"

source "$REPO_ROOT/env.sh"

# name|extra -p packages (termui is always passed)|what the test covers
TESTS=(
    "TestLayout|contrib rc2base|layout, painting and frame diffing"
    "TestInput|rc2base|input decoding"
    "TestRuntime|rc2base contrib|terminal runtime on a pty"
    "TestWidget|rc2base contrib|widgets: text input, select, spinner, progress bar, table"
    "TestApp|rc2base contrib|text field and list together in a program on a pty"
    "TestFocusKey|rc2base contrib|a focus with a key stays with its widget when others come and go"
    "TestSuspend|rc2base contrib|Suspend and the continue, with the program as a child on a pty"
    "TestProgram|rc2base contrib|Elm-style program, focus, commands and subscriptions"
    "TestControls|rc2base contrib|check box, buttons and menu bar"
    "TestCanvas|rc2base contrib|canvas: drawing, clipping and wide characters"
    "TestStyledText|rc2base contrib|styled text: wrapping, prefixes, styles and a pretty-printer Doc"
    "TestLogView|rc2base contrib|log view: following the end, scrolling and resizing"
    "TestDiffReplay|rc2base contrib|frame diffs replayed in a small terminal, with scrolled rows"
    "TestPanes|rc2base contrib|function-key guide, tab strip and splitter"
)

# Tests built with IDRIS2_CFLAGS=-D_GNU_SOURCE (posix_openpt is hidden otherwise).
NEEDS_GNU_SOURCE=" TestRuntime TestProgram TestApp TestFocusKey TestSuspend "

echo "=== Check TESTS against the tests/*/ directories ==="
listed=()
for entry in "${TESTS[@]}"; do listed+=("${entry%%|*}"); done
for d in "$TESTS_DIR"/*/; do
    t="$(basename "$d")"
    [[ "$t" == build ]] && continue
    found=0
    for l in "${listed[@]}"; do [[ "$l" == "$t" ]] && found=1; done
    [[ $found -eq 1 ]] || fail "tests/$t/ is not in the TESTS list"
done
for t in "${listed[@]}"; do
    [[ -f "$TESTS_DIR/$t/$t.idr" ]] || fail "tests/$t/$t.idr missing"
    [[ -f "$TESTS_DIR/$t/$t.expected" ]] || fail "tests/$t/$t.expected missing"
done

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && idris2 --build termui.ipkg)

echo "=== Install into the shared install/ prefix ==="
(cd "$PKG_DIR" && idris2 --install termui.ipkg)

echo "=== rc2 backend: build examples/Demo.idr (build only: it needs a terminal) ==="
rm -f "$PKG_DIR/examples/build/exec/demo"
( cd "$PKG_DIR/examples" && ulimit -v 12000000 && timeout 600 \
    "$IDRIS2RC2" --cg rc2 -p termui -p rc2base -p contrib -o demo Demo.idr )
[[ -x "$PKG_DIR/examples/build/exec/demo" ]] || fail "examples/Demo.idr did not build"
echo "=== rc2 backend: build examples/Editor.idr (build only) ==="
rm -f "$PKG_DIR/examples/build/exec/editor"
( cd "$PKG_DIR/examples" && ulimit -v 12000000 && timeout 600 \
    "$IDRIS2RC2" --cg rc2 -p termui -p rc2base -p contrib -o editor Editor.idr )
[[ -x "$PKG_DIR/examples/build/exec/editor" ]] || fail "examples/Editor.idr did not build"
echo "=== rc2 backend: build examples/LlmChat.idr (build only; it needs a terminal and a model server) ==="
rm -f "$PKG_DIR/examples/build/exec/llmchat"
( cd "$PKG_DIR/examples" && ulimit -v 12000000 && timeout 600 \
    "$IDRIS2RC2" --cg rc2 -p termui -p rc2base -p contrib -p network -o llmchat LlmChat.idr )
[[ -x "$PKG_DIR/examples/build/exec/llmchat" ]] || fail "examples/LlmChat.idr did not build"
echo "=== rc2 backend: build examples/Chat.idr (build only) ==="
rm -f "$PKG_DIR/examples/build/exec/chat"
( cd "$PKG_DIR/examples" && ulimit -v 12000000 && timeout 600 \
    "$IDRIS2RC2" --cg rc2 -p termui -p rc2base -p contrib -o chat Chat.idr )
[[ -x "$PKG_DIR/examples/build/exec/chat" ]] || fail "examples/Chat.idr did not build"

for entry in "${TESTS[@]}"; do
    IFS='|' read -r t extra desc <<< "$entry"
    pflags=(-p termui)
    for p in $extra; do pflags+=(-p "$p"); done

    echo "=== rc2 backend: build $t ($desc) ==="
    # idris2-rc2 exits 0 when only the generated C fails to compile.
    rm -f "$TESTS_DIR/$t/build/exec/${t}_verify"
    gnu_flags=""
    [[ "$NEEDS_GNU_SOURCE" == *" $t "* ]] && gnu_flags="-D_GNU_SOURCE"
    ( cd "$TESTS_DIR/$t" && ulimit -v 12000000 && IDRIS2_CFLAGS="${IDRIS2_CFLAGS:-} $gnu_flags" timeout 600 \
        "$IDRIS2RC2" --cg rc2 "${pflags[@]}" -o "${t}_verify" "$t.idr" )

    echo "=== Run and diff against $t.expected ==="
    rc=0
    ( ulimit -v 4000000; timeout 20 "$TESTS_DIR/$t/build/exec/${t}_verify" < /dev/null ) > "$TMP/actual.out" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        cat "$TMP/actual.out"
        fail "$t -- exited with status $rc (124 = 20s timeout)"
    fi
    if diff -u "$TESTS_DIR/$t/$t.expected" "$TMP/actual.out"; then
        echo "PASS  $t"
    else
        fail "$t -- output mismatch (see diff above)"
    fi
done
