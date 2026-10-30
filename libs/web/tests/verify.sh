#!/usr/bin/env bash
# One-shot correctness verification for libs/web: cleans and
# rebuilds the C support library, type-checks the package against the
# plain Chez backend, installs it into the *same* shared install/
# prefix rc2 itself uses (never a separate throwaway prefix -- a
# second, parallel install of this same package was found to go stale
# independently of the shared one, since nothing ever re-syncs the
# two, and its own package resolution could end up picking either one
# depending on search-path order; installing to the one shared
# location rc2's own env.sh already defaults to removes that
# ambiguity entirely), then builds every test under tests/<TestName>/
# (one directory per test, holding <TestName>.idr and
# <TestName>.expected) against idris2-rc-cg's own rc2 backend, runs it
# and diffs its stdout against <TestName>.expected. The TESTS list
# below is explicit; the script fails if it and the tests/*/
# directories disagree. Small-scale sibling of
# rc2/tests/verify.sh -- see that script's own header for the fuller
# rationale this one deliberately doesn't repeat.
#
# Usage: ./verify.sh
#
# Requires gcc and make on PATH, libcurl's headers for the tests that need them, rc2base installed (libs/rc2base/tests/verify.sh installs it) (the same way
# rc2/tests/verify.sh does -- idris2 itself is the self-built one,
# never nixpkgs', per AGENT.md's "Policy: don't use nixpkgs' idris2 for
# rc2 work") and rc2/build/exec/idris2-rc2 already built (see rc2/tests/verify.sh or
# rc2/README.md).

set -euo pipefail

# rc2's runtime does setlocale(LC_ALL, "") in idris2rc2_rtInit, so a
# compiled test's behaviour follows this shell's locale. Pin it
# (rc2/doc/runtime-lifecycle.md).
export LC_ALL=C.UTF-8

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
IDRIS2RC2="$REPO_ROOT/rc2/build/exec/idris2-rc2"
TMP="$(mktemp -d)"
trap 'exec 3>&- 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL  $1"; exit 1; }

# Create a FIFO for stdin that stays open but is empty (prevents tests from
# hanging on stdin reads). Tests that need stdin can write to /dev/fd/3.
mkfifo "$TMP/stdin"
exec 3<>"$TMP/stdin"

if [[ ! -x "$IDRIS2RC2" ]]; then
    fail "rc2/build/exec/idris2-rc2 not found -- build it first (see rc2/tests/verify.sh)"
fi

source "$REPO_ROOT/env.sh"

# name|extra -p packages (web and rc2base are always passed)|what the test covers
TESTS=(
    "TestHTTPServer|contrib|Network.HTTP.Server: cross-thread respond + stop, chunked request body"
    "TestHTTPMessage|contrib|Network.HTTP.Message: framing, expectation, chunked bodies, connectionClose, responseHead, findHeadEndFrom, parseHead (strict header lines), growBuffer; FromSegment Int"
    "TestAsyncHTTPServer|network contrib|Network.Async.HTTP.Server: answers, keep-alive, pipelining, split heads, HEAD/204, Connection, chunked bodies, Expect: 100-continue, 400/413/417/431/501, limits, big bodies"
    "TestAsyncHTTPStream|contrib|Network.Async.HTTP.Stream: chunk decoder, line and event parsers, events read while the server sends, framings, error status"
    "TestAsyncHTTPClient|contrib|Network.Async.HTTP.Client.Curl: the answer as a whole and in pieces, two transfers at once, a transfer given up, refused requests"
    "TestOpenAIStream|contrib|Network.HTTP.Client.WebAPI.AI.OpenAIStream: endpoint URL, pieces of a reply, a server that answers like LM Studio, errors"
    "TestAsyncHTTPStaticCGI|network contrib|Network.Async.HTTP.{Static,CGI} behind the router: files, index, ETag/304, 404 for .., CGI variables and body, Status/Location, 502, 504"
    "TestAsyncHTTPProxy|network contrib|Network.Async.HTTP.Proxy: path below the prefix, method/body/headers forwarded, hop-by-hop dropped, redirect, HEAD, 502 (unreachable, too large), 504"
    "TestAsyncHTTPRewrite|network contrib|Network.Async.HTTP.Rewrite: internal rewrites with groups and queries, whole-path match, first rule only, redirects, no //host and no .. out of the groups, rules that cannot be made"
    "TestAsyncHTTPServerTimeouts|network contrib|Network.Async.HTTP.Server timeouts: idle, stalled and trickling requests (408), idle keep-alive, a client that does not read"
    "TestAsyncHTTPServerThreads|network contrib|Network.Async.HTTP.Server: the same server on one thread and on eight (runServer); handlers overlap only with several"
    "TestWebAPIPure|network contrib|Network.HTTP.Client.WebAPI: SHA-256/base64url/PKCE, JSON, URL/form encoding, token JSON"
    "TestWebAPI|contrib|Network.HTTP.Client.WebAPI.{AI,Auth}: endpoint setup, token persistence, response decoding"
    "TestCurl|contrib|Network.HTTP.Client.Curl: libcurl bindings, local file:// and HTTP transfers"
)

# Tests that need libcurl's headers (curl/curl.h); skipped, loudly, when
# the C compiler cannot find them.
NEEDS_CURL=" TestCurl TestWebAPI TestAsyncHTTPClient "
# Tests built with IDRIS2_CFLAGS=-D_GNU_SOURCE (declarations glibc hides otherwise).
NEEDS_GNU_SOURCE=" TestAsyncHTTPStaticCGI "
have_curl_h() { echo '#include <curl/curl.h>' | gcc -E -x c - > /dev/null 2>&1; }

echo "=== Check TESTS against the tests/*/ directories ==="
# Every tests/<T>/ must be listed and have <T>.idr + <T>.expected, and
# every listed test must have its directory.
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
    [[ -d "$TESTS_DIR/$t" ]] || fail "TESTS lists $t but tests/$t/ does not exist"
    [[ -f "$TESTS_DIR/$t/$t.idr" ]] || fail "tests/$t/$t.idr missing"
    [[ -f "$TESTS_DIR/$t/$t.expected" ]] || fail "tests/$t/$t.expected missing"
done


echo "=== Clean rebuild of support/c ==="
( make -C "$PKG_DIR/support/c" clean && make -C "$PKG_DIR/support/c" )

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && idris2 --build web.ipkg)

echo "=== Install into the shared install/ prefix ==="
( cd "$PKG_DIR" && idris2 --install web.ipkg )

PKG_VERSION="$(sed -n 's/^version *= *//p' "$PKG_DIR/web.ipkg" | tr -d ' ')"
INSTALLED_LIB="$REPO_ROOT/install/idris2-0.8.0/web-$PKG_VERSION/lib"
echo "=== Check postinstall copied the native library into lib/ ==="
[[ -f "$INSTALLED_LIB/libidris2rc2web.a" ]] || fail "postinstall didn't install libidris2rc2web.a to $INSTALLED_LIB"
[[ -f "$INSTALLED_LIB/idris2rc2_web_curl_util.h" ]] || fail "postinstall didn't install idris2rc2_web_curl_util.h to $INSTALLED_LIB"

# No IDRIS2_PACKAGE_PATH export needed: idris2 already searches its
# own installation prefix (install/, the same one just installed into
# above) by default. No IDRIS2_CFLAGS/IDRIS2_LDFLAGS needed either:
# Compiler.RC2.CC's own depPkgLibDirs already adds -I<...>/lib and
# -L<...>/lib for every -p'd package's own installed lib/ (here,
# $INSTALLED_LIB) automatically -- see libs/rc2base/README.md's
# "Native library install location". idris2-rc2 always writes its -o
# output under <cwd>/build/exec/, so each test is built from inside its
# own directory (tests/<T>/build/ is git-ignored). No extra
# LD_LIBRARY_PATH is needed to run: libidris2_support.so already came
# from env.sh's own LD_LIBRARY_PATH, sourced above.
for entry in "${TESTS[@]}"; do
    IFS='|' read -r t extra desc <<< "$entry"
    if [[ "$NEEDS_CURL" == *" $t "* ]] && ! have_curl_h; then
        echo "SKIP  $t -- curl/curl.h not found by gcc (install libcurl's development files)"
        continue
    fi
    pflags=(-p web -p rc2base)
    for p in $extra; do pflags+=(-p "$p"); done

    echo "=== rc2 backend: build $t ($desc) ==="
    # idris2-rc2 exits 0 when only the generated C fails to compile; drop
    # the previous binary so that a failed build cannot pass on its output.
    rm -f "$TESTS_DIR/$t/build/exec/${t}_verify"
    gnu_flags=""
    [[ "$NEEDS_GNU_SOURCE" == *" $t "* ]] && gnu_flags="-D_GNU_SOURCE"
    ( cd "$TESTS_DIR/$t" && ulimit -v 12000000 && IDRIS2_CFLAGS="${IDRIS2_CFLAGS:-} $gnu_flags" timeout 600 \
        "$IDRIS2RC2" --cg rc2 "${pflags[@]}" -o "${t}_verify" "$t.idr" )


    echo "=== Run and diff against $t.expected ==="
    rc=0
    ( ulimit -v 4000000; timeout 20 "$TESTS_DIR/$t/build/exec/${t}_verify" <&3 ) > "$TMP/actual.out" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        cat "$TMP/actual.out"
        fail "$t -- exited with status $rc (124 = 20s timeout)"
    fi

    # Mask the random authorization URL (state, PKCE challenge, loopback
    # port) that Network.HTTP.Client.WebAPI.Auth.OAuth2.login prints.
    sed -i 's|^http://127\.0\.0\.1:[0-9]*/auth?.*|<authorization url>|' "$TMP/actual.out"
    if diff -u "$TESTS_DIR/$t/$t.expected" "$TMP/actual.out"; then
        echo "PASS  $t"
    else
        fail "$t -- output mismatch (see diff above)"
    fi
done
