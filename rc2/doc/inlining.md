# `Compiler.RC2.Inline`: whole-program `Lifted`-to-`Lifted` inlining

## Motivation

`Compiler.RC2.RC`'s `tryFuseCompare` fuses a *direct* primitive comparison
immediately consumed by a two-way Bool match into a single native
`RCmpCase` -- no boxed `Bool` is ever materialised, and the branch reads
its operands natively. This only fires when the comparison is a bare
`LOp`/`ROp` sitting right next to the match, though: when the comparison
is reached through an interface method call instead (e.g. `acc <= 0` via
`Ord Int`'s `<=`, a genuine, statically-resolved top-level function, not
a dictionary-parameterised one -- only fixed-width scalar types are ever
native-eligible to begin with), fusion never fires on its own. The
comparison sits inside `<=`'s own separate definition, invisible to the
caller's own fusion analysis.

`Compiler.RC2.Inline` closes this by splicing a small, call-free
callee's own body directly into its call site, run once, before
`Compiler.RC2.RC`'s own Phase 1 (`normalize`) ever sees the program --
so from `RC.idr`'s point of view, the call was never there. See
`rc2/tests/Test15CompareFusionThroughCall.idr` for the exact motivating
shape and how to check it via `--directive dumprcexpr`/`--directive
noinline`.

## Pipeline position

```
Lifted (upstream lambda-lifted IR)
  |
  v
Compiler.RC2.Inline   <-- this module (Lifted -> Lifted)
  |
  v
Compiler.RC2.RC (Phase 1 normalize, Phase 2 annotate)  -> RCExp
  |
  v
... Reuse / ConAltNative / MutualLoop / Loop / DualABI / Emit ...
```

Run first, before anything RC2-specific exists at all -- `Compiler.RC2.RC2`'s
own `toRCDefs` calls `applyInlineLifted` on the raw `lambdaLifted` list
before any other stage. `--directive noinline` skips it, for the same
kind of A/B regression isolation `noreuse`/`noloop`/etc. already provide
(see `RC2.idr`'s own module note on `toRCDefs`).

## Eligibility: Criterion A only

A callee is inlined at *every* one of its own call sites when:

- it's a genuine top-level definition (`MkLFun args scope body` with
  `scope = []` -- a lifted-out closure helper, which always has a
  non-empty `scope` of its own captured free variables, is never
  eligible: inlining requires a *closed* body, referencing only its own
  `args`);
- its own body is *call-free* (`isCallFree`: no `LAppName`/`LUnderApp`/
  `LApp`/`LExtPrim` anywhere in it); and
- its own body is small (`sizeOf body <= smallBodyThreshold`, currently
  24 -- a coarse structural node count, not calibrated against actual
  generated-C size).

This is deliberately narrower than a general "inline small functions"
pass. The call-free requirement means an eligible callee can never
itself contain a further call to inline -- so `inlineLifted`'s own
whole-program rewrite needs only one pass, never a fixpoint: splicing in
a call-free body can't expose a *new* inlining opportunity inside what
was just spliced (only inside the call's own *arguments*, which are
processed bottom-up before the call itself is considered).

A second criterion (single call site, whole-program, ordered via a
Tarjan-SCC call graph reusing `Compiler.RC2.MutualLoop`'s own `Graph`/
`tarjanSCCs`) was investigated in an earlier session alongside Criterion
A, but confirmed *not* to reach the separately-documented monadic-bind
reuse gap (`rc2/doc/reuse-monadic-bind-gap.md`) and not otherwise
load-bearing for any currently-known gap. Not implemented here, to keep
this pass's own blast radius matched to the problem it actually solves;
`Graph`/`tarjanSCCs` were still made `public export`/`export` in
`MutualLoop.idr` in case a future session revisits this.

## The `allLiteralArgs` guard

A call whose arguments are *all* bare `LPrimVal` literals is never
inlined, even if otherwise eligible. Found necessary via
`Test6NativeInts.idr`'s own `chainInt8 100 100`-shaped calls: once a
fixed-width arithmetic chain is spliced in with every operand a
compile-time constant, gcc's own `-Werror=overflow` can statically prove
an intentional two's-complement wraparound "overflows," turning a
correct, deliberate test into a compile error. Vacuously true for a
nullary call (no arguments to be "all literal" over), so the guard only
ever actually fires once there's at least one argument -- a nullary
call has no such folding risk in the first place.

## IR plumbing: `Weaken`/`Substitutable` for `Lifted`

Splicing a callee's body into a call site is a capture-avoiding
substitution: replace every occurrence of a callee argument with the
corresponding caller-side expression, correctly re-indexing every local
variable reference along the way. `Lifted`'s own `LLocal` uses the exact
same `IsVar`-based de Bruijn representation as `Core.TT.Term`'s own
`Local`, so this module ports `Core.TT.Term`'s own `insertNames`/
`GenWeaken`/`FreelyEmbeddable` instances and `Core.TT.Term.Subst`'s own
`substTerm`, verbatim in structure, onto `Lifted`/`LiftedConAlt`/
`LiftedConstAlt` -- no `Lifted`- or rc2-specific capture-avoidance
machinery needed at all; the generic `Core.TT.Var`/`Core.TT.Subst`
combinators (`insertNVarNames`, `find`) do all the actual index
arithmetic.

Two things `Term`'s own instances never needed, since `Term`'s own
`Bind` only ever introduces one name at a time:

- **`LiftedConAlt`'s multi-name binder.** A constructor alternative
  binds a whole *list* of names (`args`) at once
  (`Lifted (args ++ vars)`), not just one -- `insertNamesConAlt`/
  `substConAlt` need one extra `appendAssociative` reshuffle to line the
  types up, ported from upstream `Compiler.CaseOpts`'s own
  `shiftBinderConAlt`, which already solves the identical shape for
  `CConAlt`.
- **Erasure.** `Lifted`'s own `vars` scope index is never used at
  runtime by *any* constructor except inside an already-erased `IsVar`
  proof (`LLocal`'s own `(0 p : IsVar x idx vars)`) -- Idris2's own
  forced-argument detection erases it throughout automatically. Every
  helper this module adds that mentions a scope-list implicit by name
  (`insertNamesConAlt`, `substConAlt`, `toSubst`, `inlineCall`) has to
  mark it `0` explicitly to match, or the compiler rejects the call with
  "`<name>` is not accessible in this context" -- `Lifted`'s own erased
  index simply doesn't carry the runtime information a non-erased
  parameter would need. This is also *why* `FreelyEmbeddable Lifted`'s
  own `embed` (append-on-the-right, used to widen a closed callee body
  into the caller's own scope before substituting) can just be
  `believe_me`: with zero runtime information in the index either way,
  there is nothing an unsafe cast could get wrong.
- **`SizeOf` from a `Subst`'s own spine, not `mkSizeOf`.** `inlineCall`
  needs a `SizeOf calleeArgs` to seed the substitution, but `calleeArgs`
  is erased in its own context, so `mkSizeOf calleeArgs` (which
  genuinely counts a real list's length) can't be used. `env`'s own
  `Subst` value already encodes that length as real, non-erased
  cons-spine structure, so `sizeOfSubst` reads it from there instead.

## Case-of-case collapse

Substituting a call's own scrutinee-shaped argument into a `case`
position produces a "case of case" -- `case (case x of ...) of ...` --
that `tryFuseCompare` doesn't recognise on its own. `collapseCaseOfCase`
ports upstream `Compiler.CaseOpts`'s own `doCaseOfCase`/
`doCaseOfConstCase`/`tryCaseOfCase` (the `CExp`-level case-of-case half
only -- `Lifted` has no `LLam` at all, since lambda-lifting already
eliminated every lambda, so upstream's own "lift out lambda" half,
`caseLam`, has no counterpart here) onto `Lifted`, and applies it
bottom-up across the whole tree after inlining. To bound the risk of
duplicating a large outer case into every inner branch, collapsing only
fires when the inner case's own alternatives are all constructor-headed
(or there's exactly one, with no default) -- identical restriction to
upstream's own `canCaseOfCase`.

## Bugs found and fixed

An earlier attempt at this pass, this session, was fully reverted after
the full regression suite surfaced a real, `valgrind`-confirmed leak in
`Test9SelfTailLoop`'s own `collatzLike` once inlining made comparison
fusion reach a self-tail-loop's own accumulator for the first time. Two
rounds of narrowing the case-of-case collapse (bounding it, then
disabling it outright) left the leak byte-for-byte unchanged, and the
attempt was shelved with the root cause undiagnosed (see `TODO.md`'s own
git history for that investigation).

The real root cause, found in the *next* session by reproducing the leak
with a hand-written source program containing zero function calls to
inline at all, turned out to be two completely independent, pre-existing
bugs, neither one in this pass:

- `Compiler.RC2.Loop`'s own `RLoopContinue` (the self-tail-loop
  continuation node `applyLoop` produces) had no `postDrop` field at
  all, unlike every other RCExp construct that reads a Boxed value
  natively (`ROp`/`RCmpCase`/`RAppNameRep`) -- so a native-shadowed loop
  parameter fed by a still-Boxed, `case`-valued continuation argument
  got read natively but never dropped.
- `Compiler.RC2.Emit`'s own `ROp` case fabricated an anonymous, unfreed
  Boxed wrapper (`rcVarToBoxedC`'s own `nativeMk`) whenever a
  Boxed-result op read an individually-Native operand -- a `case`/
  `if`-valued `RLet`'s own Rep never promotes to Native
  (`Types.repOf`), so a genuinely native arithmetic chain living inside
  one of its branches still had to be boxed on the fly to feed a Boxed
  C primitive, and that ephemeral box had nowhere to be dropped.

Both are fixed (see `rc2/doc/loop-conversion.md`'s "Bugs found and
fixed" #5 for the full write-up) independently of this pass -- neither
fix touches `Inline.idr` at all. This pass's own logic (the IR plumbing,
the case-of-case collapse, both eligibility criteria) was already
correct at the point the original leak was found, confirmed via
`--directive dumprcexpr` on the motivating comparison-fusion case both
then and after this reimplementation.

A separate, narrower bug specific to *this* implementation attempt: the
`--directive noinline` wiring was silently broken partway through the
original debugging session (`toRCDefs` called `applyInlineLifted`
unconditionally, and `"noinline"` was missing from `compileExpr`'s own
recognised-directives list), which produced a wrong intermediate
conclusion ("the leak is pre-existing, unrelated to this pass") since
both compared builds secretly had inlining enabled. Re-verified this
time by diffing the generated C with and without `--directive noinline`
before trusting any A/B comparison built on it again (see
`rc2/tests/Test14SmallFunctionInline.idr`'s and
`Test15CompareFusionThroughCall.idr`'s own doc comments, which both
describe exactly what to expect changed between the two builds).

## Files

- `rc2/src/Compiler/RC2/Inline.idr` -- this pass, in full.
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `Graph`/`tarjanSCCs`, made
  `public export`/`export` for reuse here (Criterion B, not currently
  implemented -- see above).
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own wiring,
  `compileExpr`'s own `"noinline"` directive.
- `rc2/tests/Test14SmallFunctionInline.idr`,
  `rc2/tests/Test15CompareFusionThroughCall.idr` -- dedicated regression
  tests for Criterion A and the motivating comparison-fusion case
  respectively.

## Verification methodology

1. Build (`idris2 --build rc2.ipkg`) and runtime (`support/rc2`'s own
   `make && make install`).
2. `rc2/tests/verify.sh`: 19/19 refc-suite, every smoke test, valgrind
   clean on every `LEAK_SENSITIVE_TESTS` entry except the one
   long-recorded pre-existing `Test1Basics` leak.
3. `--directive dumprcexpf`, compared against `--directive dumprcexpf
   --directive noinline` on `Test15CompareFusionThroughCall.idr`:
   confirms the interface call disappears, replaced by a single native
   `cmp <=Int [...]`, and that `step`'s own worker parameter goes from
   `Boxed` to `Native Int` as a direct consequence.
4. `rc2/tests/bench.sh`: no timing regression on the existing
   micro-benchmark suite.
