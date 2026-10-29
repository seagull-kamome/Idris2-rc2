#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# Every comparison of two known strings folds (rc2/doc/const-caf-fold.md,
# "String literals"); the two left read the command line (`dyn == greeting`)
# or go through `pack . unpack` (`re a == re b`).
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"

cmps="$(grep -c 'cmp ==String' "$dump" || true)"
if [ "$cmps" = "2" ]; then
    pass "string comparisons: only the run-time ones are left"
else
    fail "expected 2 'cmp ==String' (the run-time ones), found $cmps in $dump"
fi

# `case codegen of "rc2" => ...` and `describe codegen` are decided at compile
# time: a string case is left only for `describe dyn`.
cases="$(grep -cE '^ +"(rc2|hello)" ->' "$dump" || true)"
if [ "$cases" -le 2 ]; then
    pass "string cases: only the run-time one is left ($cases alt lines)"
else
    fail "expected at most 2 string-case alt lines (describe dyn), found $cases in $dump"
fi

# The folded order comparisons must not depend on the locale: the runtime
# compares bytes (idris2rc2_strcmp3), and so does the fold.
want="$(cat "$(dirname "$0")/$name.expected")"
for loc in C.utf8 en_US.utf8 ja_JP.utf8; do
    if locale -a 2>/dev/null | grep -qix "$loc"; then
        if [ "$(LC_ALL=$loc "$TMP/${name}_rc2" 2>&1)" = "$want" ]; then
            pass "output unchanged under LC_ALL=$loc"
        else
            fail "output differs under LC_ALL=$loc"
        fi
    fi
done
