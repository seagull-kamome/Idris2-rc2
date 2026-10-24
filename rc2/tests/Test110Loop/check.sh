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

# Loop-invariant hoisting (doc/loop-conversion.md, "Loop-invariant
# expression hoisting"): a division by a literal is hoisted out of the
# loop, a division by a variable stays inside it behind its zero check
# (hoisted, it would trap with SIGFPE for y == 0, which the output diff
# also catches).
divPlace() {
    awk -v f="$1" '
        /^def / { on = (index($0, f) > 0); inloop = 0; next }
        on && /^  loop \[/ { inloop = 1 }
        on && /op \/Int / { print (inloop ? "inside" : "outside"); exit }' "$d"
}
# sumDivLiteral is inlined into `run`: its hoisted division is the
# `op /Int [_, #7]` sitting right before the `loop [`.
if grep -A1 'op /Int \[v[0-9]*, #7\]' "$d" | grep -q '^ *loop \['; then
    lit=outside
else
    lit=inside
fi
var="$(divPlace sumDivGuarded)"
if [ "$lit" = "outside" ] && [ "$var" = "inside" ]; then
    pass "LoopInvariant -- literal divisor hoisted, variable divisor kept inside the loop"
else
    fail "LoopInvariant: sumDivLiteral division $lit (want outside), sumDivGuarded division $var (want inside)"
fi
