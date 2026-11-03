#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

d="$TMP/${name}_rc2.rcexpr"

for spec in "pick:partial" "pickStr:partial"; do
    f="${spec%%:*}"
    kw="${spec##*:}"
    body="$(awk -v f="Main.$f" '
        $0 ~ "^def " f " " { on = 1; next }
        /^def / { on = 0 }
        on { print }' "$d")"
    before="$(printf '%s\n' "$body" | awk -v kw="$kw" '/^  case /{exit} $0 ~ "^ +(let .*=)?" kw " " {n++} END{print n+0}')"
    nothing="$(printf '%s\n' "$body" | awk -v kw="$kw" '/NOTHING/{on=1; next} /JUST/{on=0} on && $0 ~ kw " " {n++} END{print n+0}')"
    if [ "$before" = "0" ] && [ "$nothing" = "1" ]; then
        pass "Sink -- $f builds its $kw only in the arm that returns it"
    else
        fail "Sink: $f has $before $kw before its case and $nothing in the NOTHING arm (want 0 and 1)"
    fi
done
