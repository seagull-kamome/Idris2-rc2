#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

d="$TMP/${name}_rc2.rcexpr"

# Compiler.RC2.MutualLoop (doc/loop-conversion.md): a group of two or
# more mutually tail-recursive functions becomes ONE function
# `{rc2_mutualLoop:N}` that dispatches on a leading tag and then loops,
# and each member shrinks to `call {rc2_mutualLoop:N} [#tag, ...]`. The
# output diff only shows that the deep recursion does not crash, not that
# the merge happened. SelfTailLoop.idr has three groups: isEvenM/isOddM,
# stepA/stepB (different arities) and the cycleA/cycleB/cycleC cycle.
merged="$(grep -c '^def {rc2_mutualLoop:' "$d" || true)"
if [ "$merged" = "3" ]; then
    pass "MutualLoop -- 3 merged group functions"
else
    fail "MutualLoop: $merged merged group function(s) in $d, expected 3"
fi

# Every member that is still defined is a stub that only calls its
# group's function with its tag. isEvenM, isOddM, stepA and cycleA are
# called from the test, so they must be there; stepB, cycleB and cycleC
# are only reached through the merged function and DeadCode drops them.
bad=""
for f in isEvenM isOddM stepA stepB cycleA cycleB cycleC; do
    body="$(awk -v f="Test110Loop.SelfTailLoop.$f" '
        $0 ~ "^def " f "  " { on = 1; next }
        /^def / { on = 0 }
        on && NF { print }' "$d")"
    if [ -z "$body" ]; then
        case " stepB cycleB cycleC " in *" $f "*) continue ;; esac
        bad="$bad $f(missing)"
        continue
    fi
    n="$(printf '%s\n' "$body" | wc -l)"
    if [ "$n" != "1" ] || ! printf '%s\n' "$body" | grep -q '^  call {rc2_mutualLoop:[0-9]*} \[#[0-9]*, '; then
        bad="$bad $f"
    fi
done
if [ -z "$bad" ]; then
    pass "MutualLoop -- every remaining group member is a one-line call into its merged function"
else
    fail "MutualLoop: not a stub calling {rc2_mutualLoop:N}:$bad"
fi

# A merged function holds the loop and no call back to a member (that is
# the whole point: no trampoline, no stack growth), and ends in the tag
# dispatch's unreachable default.
bad=""
for id in $(grep -o '^def {rc2_mutualLoop:[0-9]*}' "$d" | grep -o '[0-9]*'); do
    body="$(awk -v id="$id" '
        $0 ~ "^def {rc2_mutualLoop:" id "}" { on = 1; next }
        /^def / { on = 0 }
        on { print }' "$d")"
    printf '%s\n' "$body" | grep -q '^  loop \[' || bad="$bad $id(no loop)"
    printf '%s\n' "$body" | grep -q 'continue loop' || bad="$bad $id(no continue)"
    printf '%s\n' "$body" | grep -q 'MutualLoop tag dispatch fell through' || bad="$bad $id(no default)"
    if printf '%s\n' "$body" | grep -q 'call Test110Loop.SelfTailLoop.\(isEvenM\|isOddM\|stepA\|stepB\|cycleA\|cycleB\|cycleC\)'; then
        bad="$bad $id(calls a member)"
    fi
done
if [ -z "$bad" ]; then
    pass "MutualLoop -- each merged function loops, dispatches on its tag, and calls no member"
else
    fail "MutualLoop: merged function(s) malformed:$bad"
fi
