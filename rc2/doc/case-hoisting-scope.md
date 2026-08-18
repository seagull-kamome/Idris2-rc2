# Loop-invariant constructor-field hoisting: investigated, not pursued

This document records why hoisting a loop-invariant, single-alternative
`RConCase` destructure out of a loop body was investigated and then
dropped, so a future session doesn't have to re-derive this before
picking the idea back up. It also covers a second entry that turned out
to be the same underlying gap wearing a different name --
`Compiler.RC2.ConAltNative`'s once-planned extension across loop/
dual-ABI boundaries (see "A related gap" below) -- dropped for the same
reasons.

## Motivation

Found while reading the `--directive dumprcexpr` dump of
`idris2-missing-containers`' `Data.Hash.Algorithm.Internal.feedCharOfString.go`
(see `rc2/BENCHMARKS.md`'s 2026-08-18 closure in-place growth entry --
this is the loop that motivated that change). Its loop body re-executes
a `case v0 of HashAlgorithm ... args=[..., v20, ...]` every iteration
purely to extract one interface-dictionary method closure, even though
the match has exactly one alt (a record, so no default is needed), so
which branch runs is already known before the loop even starts.
`Compiler.RC2.Loop`'s loop-invariant parameter elision already removes
`v0` itself from the loop's own carried params, since it's passed
unchanged through every continue -- but the `case` inside the loop body
is untouched by that pass, so the redundant re-match/re-`dup` of `v20`
still happens every single iteration.

## What the investigation found

**`Emit.idr` already elides the branch condition itself.** `emitAltChain`
(`rc2/src/Compiler/RC2/Emit.idr`, doc comment at the definition) already
special-cases a single-alt `RConCase` with no default: "a single-alt
case with no default (only one constructor is even possible) collapses
further still, to no `if` at all." The same applies to zero alts plus a
lone default. So the `if`/`switch` dispatch cost this entry originally
worried about is already gone by the time C is emitted -- confirmed by
reading `emitAltChain`'s `chained`/`condAlts`/`tailAlt` logic, not just
inferred. What's left, every iteration, is exactly the destructure
itself (reading `sc->args[k]` into a fresh local) plus that field's own
`RDup` -- real but smaller cost than originally framed.

**Two ways to actually hoist that remaining cost were considered:**

1. **General single-alt-case flattening**: rewrite any single-alt (or
   alt-less-plus-default) `RConCase` into a flat `RLet` chain -- one
   `RLet` per destructured field, then the alt's own body -- and drop
   the `RConCase` node entirely. Loop-invariance would then fall out
   for free from `Compiler.RC2.Loop`'s existing `isInvariantExpr`/
   `hoistInvariantPrefix` machinery, with no new loop-specific pass
   needed.

   This doesn't work without a new IR node first. `RConAlt.args : List
   Int` (`RCExp.idr`) is not an independent expression -- it only means
   anything in the context of the enclosing `RConCase`'s own `sc`;
   there's no "read field `k` of constructor `sc`" expression an `RLet`
   could hold as its `value`. Introducing one (e.g. an `RGetField`
   node) would touch every structural-analysis function in `RCExp.idr`
   (`freeLocalsR`/`countUsesR`/`usedConstructorsR`), `Compiler.RC2.Reuse`
   (`dupOnShared` computation, `RReuseOffer` interaction), `Emit.idr`
   (a new lowering case), and `Compiler.RC2.Loop`'s invariance check --
   a genuinely new IR primitive, not a small local change, for a gap
   that (per the point above) is now known to be strictly narrower
   than originally scoped.

2. **Loop-specific restructuring, no new node**: instead of flattening,
   hoist the whole `RConCase` out and wrap the loop *inside* the
   surviving alt's body (`RConCase sc [MkRConAlt ... (RLoop ...)]
   Nothing` instead of `RLoop ... (RConCase sc [...] Nothing)`). This
   stays within the existing `RConCase`/`RLoop` vocabulary -- no new
   node -- but only ever applies to the loop-plus-single-alt-case shape
   specifically; it wouldn't generalize to a single-alt case outside a
   loop, and would be its own dedicated pass either way.

## Why neither was pursued

Once the `if`-elision fact above was on the table, the remaining upside
(saving one destructure+dup per iteration on an already-narrow shape:
single-alt case, loop-invariant scrutinee, still executed) no longer
justified either cost: option 1 needs a genuinely new IR primitive with
wide blast radius for a benefit smaller than originally believed;
option 2 avoids the new primitive but buys only a narrow, loop-specific
special case -- effectively one more single-purpose pass alongside the
ones `Compiler.RC2.Loop`/`Compiler.RC2.Sink` already are, for a cost
that's now known to be "one dup, once per iteration," not "one branch
dispatch, once per iteration."

Decision: **dropped, not currently planned.** Revisit only if profiling
turns up a concrete case where this specific dup-per-iteration cost
(not the already-elided branch dispatch) actually matters.

## A related gap: `ConAltNative`'s loop/dual-ABI-boundary extension

`Compiler.RC2.ConAltNative` (see `rc2/doc/con-alt-native.md`) caches a
repeatedly-native-read constructor-destructured field, but only within
a single case-alternative's own body. `TODO.md` used to carry a
separate entry proposing to extend that caching across a loop
iteration boundary or a dual-ABI call boundary -- i.e. keep a native
shadow of a field of a **loop-carried constructor** alive across
iterations, instead of re-destructuring and re-caching it every time
the loop body re-enters the `case`.

This is the same gap as the single-alt-case hoisting above, just
described starting from `ConAltNative` instead of from the loop:
`feedCharOfString.go`'s own `v0`/`v20` example (Motivation, above) *is*
a loop-carried-constructor case, and a native shadow for `v20` that
survived across iterations is exactly what this extension would have
produced. Concretely, implementing it means solving the same problem
option 2 above already solves for the general case -- restructuring so
the `case` runs once, outside the loop, with the loop nested inside the
surviving alt's body -- and then layering `ConAltNative`'s existing
per-alt shadow caching on top, now running just once instead of once
per iteration. It doesn't need a new IR node the way option 1 does
(`ConAltNative`'s shadow-and-rename mechanism, `doc/con-alt-native.md`'s
"Design", already works over existing nodes), but it inherits option
2's own narrowness: still a dedicated pass for one specific shape, not
a general mechanism, and gated on the same loop-restructuring machinery
this document already declined to build for a smaller-than-expected
payoff.

The dual-ABI-boundary half of the original proposal (a native shadow
surviving *across a function call*, not just loop iterations) was never
even scoped this closely -- it would need `ConAltNative` to reason about
a constructor field's shadow status at a call site, an extension to
`Compiler.RC2.DualABI`'s own argument/return Rep negotiation that was
never designed, on top of everything above.

Decision: **dropped, not currently planned**, for the same reason as
the loop-invariant case-hoisting entry above -- the piece that would
make it worth doing (the loop-restructuring transform) was already
declined on its own merits.

## Files

- `rc2/src/Compiler/RC2/Emit.idr` -- `emitAltChain`'s own doc comment,
  the "no `if` at all" single-alt/no-default collapse this document's
  finding rests on.
- `rc2/src/Compiler/RC2/RCExp.idr` -- `RConAlt`/`RConCase`, `RLet`;
  where a hypothetical `RGetField`-style node would need to slot in.
- `rc2/src/Compiler/RC2/Loop.idr` -- `isInvariantExpr`/
  `hoistInvariantPrefix`, the existing loop-invariant-hoisting
  machinery a flattened `RLet` chain would have piggybacked on.
- `rc2/BENCHMARKS.md` -- 2026-08-18 closure in-place growth entry,
  where this loop shape was first found.
- `rc2/src/Compiler/RC2/ConAltNative.idr`, `rc2/doc/con-alt-native.md`
  -- the existing single-alt-body field-shadow caching this document's
  "related gap" section builds on.
