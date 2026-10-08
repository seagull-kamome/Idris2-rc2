#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Struct return (doc/struct-return.md) shows in the dump as the workers
# that return a struct, and its width and layout: `step`'s carries its
# `Int` natively (`Ret1:1=Int`), `lookupAge`'s has a `Nothing` tail
# (`Ret1`), `halves`' two Boxed fields (`Ret2`), `qr`'s two native ones
# (`Ret2:1=Int,Int`), and `segOf` shares `shapeOf`'s three-field struct
# through a tail call (`Ret3:1=Int,Int,Boxed:2=Int,Int,Int`); `halfOf`
# (only ever a closure, so no caller gains) returns none.
# `--directive nostructreturn` fails this.
dump="$TMP/${name}_rc2.rcexpr"
retOf() { grep -c "^def {idris2rc2_worker_Main_$1:[0-9]*} .* ret= $2 " "$dump" || true; }
step="$(retOf step 'Ret1:1=Int')"
lookupAge="$(retOf lookupAge Ret1)"
halves="$(retOf halves Ret2)"
qr="$(retOf qr 'Ret2:1=Int,Int')"
segOf="$(retOf segOf 'Ret3:1=Int,Int,Boxed:2=Int,Int,Int')"
shapeOf="$(retOf shapeOf 'Ret3:1=Int,Int,Boxed:2=Int,Int,Int')"
halfOf="$(grep -c '^def .*Main_halfOf.* ret= Ret' "$dump" || true)"
if [ "$step$lookupAge$halves$qr$segOf$shapeOf$halfOf" = "1111110" ]; then
    pass "struct return -- step, lookupAge, halves, qr, segOf and shapeOf return their structs, halfOf none"
else
    fail "struct workers step=$step lookupAge=$lookupAge halves=$halves qr=$qr segOf=$segOf shapeOf=$shapeOf halfOf=$halfOf in $dump"
fi

# The mutual-recursion additions (doc/struct-return.md, "Eligibility"):
# the two `MutualLoop`-merged groups (`seekEven`/`seekOdd` returning a
# `Maybe Int`, `runA`/`runB`/`runC` returning a two-field record) each get
# a struct-return worker, and the non-tail pair `splitA`/`splitB` (no
# merge) does too. `--directive nomutualstruct` leaves the merged
# functions with cell returns, so this fails there.
merged="$(grep -c "^def {idris2rc2_worker_rc2_mutualLoop_[0-9]*:[0-9]*} .* ret= Ret" "$dump" || true)"
splitA="$(retOf splitA Ret2)"
splitB="$(retOf splitB Ret2)"
if [ "$merged$splitA$splitB" = "211" ]; then
    pass "struct return -- both MutualLoop-merged groups and splitA/splitB return structs"
else
    fail "merged workers=$merged splitA=$splitA splitB=$splitB in $dump"
fi
