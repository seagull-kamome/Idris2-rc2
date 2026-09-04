# Whole-program CAF folding and `RConCase` scrutinee resolution

`Compiler.RC2.ConstFold`'s `RCConstCon`/`RCConstClosure` folding (see
`rc2/doc/const-con-fold.md`/`rc2/doc/const-closure-fold.md`) used to
fold *only within one definition's own body*, via a single pass with a
fresh, purely-local `env` per definition (`foldConstDef`, called once
per `RCDef`, no cross-definition state). Two gaps followed from that:
a `RAppName` call to another top-level 0-argument definition (a CAF)
that itself folded entirely to a constant was never treated as
constant at the call site, and `RConCase` (constructor-tag dispatch --
also what an ordinary record field projection desugars to, via a
single-alt `case`) never resolved its own scrutinee against a
known-constant value the way `RConstCase` (literal/`Constant` dispatch)
already did.

This document covers the two closing mechanisms (`TODO.md`'s former
"Performance: constant-constructor folding doesn't cross a CAF
boundary or a case scrutinee" entry, now fully resolved and removed
from there), the `noconstfold` directive that gates the whole thing,
one real bug found and fixed while wiring `RConCase` folding into
`Compiler.RC2.RC`'s ownership annotation, and the four new regression
tests.

## Design

### CAF boundary crossing: a whole-program fixpoint

`ConstFold.idr` gains a second, wider table alongside the existing
per-definition `Env` (`SortedMap Int (Subset RCLocal
IsAnyConstLocal)`, keyed by `RCLoc`'s own local id):

```idris2
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)
```

(`ConstFold.idr:183-185`). `CafTable` is keyed by `Name`, since a CAF
call crosses definition boundaries where a local id has no meaning.
`foldConst` now takes a `CafTable` alongside `Env` everywhere, and its
`RAppName` case resolves a CAF reference the same way `RLet`'s value
classification already resolves a local variable:

```idris2
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
```

(`ConstFold.idr:312-318`). `args' = []` is exactly a CAF call (a
0-argument top-level definition is always applied with an empty `args`
list); a non-empty `args'` is an ordinary call and is left alone but
for having its own operands resolved, same as every other node. A
resolved CAF reference becomes a bare `RV fc cval`, which flows into
`env` through the very same `RLet`/`RV` classification arms
`RCConstCon`/`RCConstClosure` folding already had (`ConstFold.idr:
237-258`) -- no separate mechanism needed for what happens after
substitution.

Building `CafTable` itself is a whole-program pass,
`Compiler.RC2.RC2.foldConstProgram`:

```idris2
foldConstProgram : List (Name, RCDef) -> List (Name, RCDef)
foldConstProgram defs0 = go maxConstFoldIterations empty defs0
  where
    rebuildTable : List (Name, RCDef) -> CafTable
    rebuildTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    go : Nat -> CafTable -> List (Name, RCDef) -> List (Name, RCDef)
    go Z _ defs = defs
    go (S fuel) table defs =
        let folded = map (\(n, d) => (n, foldConstDef table d)) defs
            table' = rebuildTable folded
        in if length (SortedMap.toList table') == length (SortedMap.toList table)
              then folded
              else go fuel table' folded
```

(`RC2.idr:137-150`). Each round runs `foldConstDef` (unchanged in
shape, just now taking the current `CafTable`) over every top-level
definition, then rebuilds the table from whichever definitions now
have the shape `cafValueOf` recognises:

```idris2
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf _ = Nothing
```

(`ConstFold.idr:417-419`) -- a 0-arg `MkRCFun` whose body has folded
down to a bare `RV fc cval`. A bare `RPrimVal` body is deliberately
*not* matched here: a CAF that simple is already spliced into every
call site by `Compiler.RC2.Inline`'s own `isCallFree (LPrimVal _ _) =
True` before `ConstFold` ever runs, so by the time `cafValueOf` looks,
it's gone; only the `RCConstCon`/`RCConstClosure` shapes `Inline` can't
reach (`isCallFree`'s own `LCon`/`LUnderApp` cases, see
`const-con-fold.md`/`const-closure-fold.md`) still need this route.

The loop terminates either once `CafTable`'s own key count stops
growing between rounds, or after `maxConstFoldIterations = 4`
(`RC2.idr:127-128`) -- chosen to match GHC's own
`-fmax-simplifier-iterations` default, on the same reasoning: two
safety properties make an outer cap safe rather than merely
convenient. A definition can only ever transition from *not yet known
constant* to *known constant*, never back, so the process is
monotonic; and a group of mutually-referencing CAFs that can never
resolve to a flat constant (`a = More 1 b; b = More 2 a`) simply never
makes further progress on that group and is left as ordinary,
dynamically-computed definitions -- hitting the cap only means some
deeply-chained CAFs stay unfolded (a missed optimisation), never an
incorrect fold.

`Compiler.RC2.RC2.toRCDefs` wires the whole thing in between Phase 1
normalization and Phase 2 annotation:

```idris2
preFolded <- ... traverse (\(n, ld) => do d <- toRCDefPreFold n ld; pure (n, d)) lds
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
reused <- ... traverse (\(n, d) => do d1 <- toRCDefPostFold d; ...) folded
```

(`RC2.idr:152-165`) -- `toRCDefPreFold`/`toRCDefPostFold` are `RC.idr`'s
existing Phase 1/Phase 2 split (unmodified by this change); the
fixpoint loop sits entirely between them, seeing only Phase 1's
already-normalized-but-not-yet-annotated IR, same as the old one-shot
`foldConstDef` call did.

### `RConCase` scrutinee resolution

`RConstCase`'s own `foldConst` case already resolved its scrutinee:

```idris2
foldConst caf env (RConstCase fc sc alts mDef) =
    let alts' = map (foldConstConstAlt caf env) alts
        mDef' = map (foldConst caf env) mDef
    in case resolveConst env sc of
            Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
            Nothing => RConstCase fc sc alts' mDef'
```

(`ConstFold.idr:375-380`). `RConCase` needed the same shape, but
picking an alt by constructor *tag* rather than `Constant` equality,
and -- unlike a `RConstCase` alt, which binds nothing -- substituting
each matched alt's own field-bound local ids with the corresponding
sub-value already sitting inside the resolved `RCConstCon`'s own
`args`. Two small helpers do this:

```idris2
findConAlt : Maybe Int -> List RConAlt -> Maybe RConAlt
findConAlt tag [] = Nothing
findConAlt tag (alt@(MkRConAlt _ _ tag' _ _) :: rest) =
    if tag == tag' then Just alt else findConAlt tag rest

insertConArgs : List Int -> List RCLocal -> Env -> Env
insertConArgs (i :: is) (v :: vs) env =
    case isConstLocalProof v of
         Just prf => insertConArgs is vs (insert i (Element v prf) env)
         Nothing  => insertConArgs is vs env
insertConArgs _ _ env = env
```

(`ConstFold.idr:187-197`), and `foldConst`'s own `RConCase` case:

```idris2
foldConst caf env (RConCase fc sc alts mDef) =
    case resolveLocal env sc of
         RCConstCon _ _ tag args =>
             case findConAlt tag alts of
                  Just (MkRConAlt _ _ _ argIds body) =>
                      foldConst caf (insertConArgs argIds args env) body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         RCEmptyCon _ _ tag =>
             case findConAlt (Just tag) alts of
                  Just (MkRConAlt _ _ _ _ body) => foldConst caf env body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         _ => RConCase fc sc (map (foldConstAlt caf env) alts) (map (foldConst caf env) mDef)
```

(`ConstFold.idr:359-374`). `insertConArgs` calling `isConstLocalProof`
on each field is not optional plumbing: `RCon`'s own folding
(`ConstFold.idr:288-294`) only ever produces a `RCConstCon` when
*every* field already satisfies `IsAnyConstLocal`, so in practice every
field substituted here does have a proof and gets tracked in `env`
exactly like a genuinely folded local would -- the `Nothing` branch
exists for totality, not because it's expected to fire on a
`RCConstCon`'s own `args`. `RCEmptyCon` (NIL/NOTHING/ZERO/UNIT) needs
no field substitution at all -- it carries no fields by construction --
so its branch just matches by tag and recurses into the chosen alt's
body directly.

The `RCrash "...matched no alt and had no default"` branch is a
defensive totality closer, not a code path this pass expects to
reach in practice: upstream Idris2's own exhaustiveness checking
guarantees a well-typed `case` covers every constructor of its
scrutinee's type (directly, or via a default), so a resolved
`RCConstCon`/`RCEmptyCon` whose tag matches nothing among `alts` and
has no `mDef` would mean the *source* program's own case coverage was
already unsound -- not something `ConstFold` itself could cause.

Since `RConCase` and `RConstCase` share `foldConst`'s single mutual
block, a scrutinee whose own constancy is only established by a
later-processed CAF (via `RAppName`'s fold arm) benefits from the same
outer fixpoint loop automatically -- no separate re-triggering
mechanism was needed for this half either.

## Bugs found and fixed

### `RC.idr`'s `annotate` was missing 3 of 5 constant-form intercepts

`RC.idr`'s Phase 2 ownership annotation, `annotate`, already
special-cased two of `RCLocal`'s five constant forms as "immortal,
never needs a dup, never tracked as owned/borrowed":

```idris2
annotate natives owned e@(RV _ (RCConstCon {})) = pure e
annotate natives owned e@(RV _ (RCConstClosure {})) = pure e
```

(`RC.idr:474,478`, predating this change). The other three forms
(`RCConst`, `RCEmptyCon`, `RCNull`) had no equivalent intercept in
`annotate` itself -- harmless before this change, because those three
only ever reached `annotate` already wrapped inside a `RLet` (handled
by a separate code path) or as an ordinary variable reference, never as
a bare, unwrapped `RV` of one of these forms with no enclosing binder.
`insertConArgs` breaks that assumption: substituting a `RConCase`
alt's own field-bound local id directly with (say) a resolved
`RCConst`/`RCEmptyCon`/`RCNull` sub-value, then folding straight into
that alt's body, can produce exactly such a bare `RV` reaching
`annotate` for the first time with nothing above it.

Without the fix, `annotate`'s generic fallback --

```idris2
annotate natives owned (RV fc v) =
    pure $ if contains v natives || contains v owned then RV fc v else RDup fc v (RV fc v)
```

-- wraps it in a real `RDup fc v ...`, since neither `natives` nor
`owned` ever tracks a constant-form value. `Compiler.RC2.EmitUtil`'s
`varName` has no rendering for any of these five forms reaching a
`RDup` this way (by design -- this was previously unreachable), which
surfaced as a genuine C compile error, not a wrong answer or a silent
leak:

```c
idris2rc2_dup(/* [rc2] unreachable RCConst varName */)
```

-- a call with too few arguments, since the placeholder comment
substitutes for the actual variable name `RDup`'s emission expects.

**Fix**: add the same three intercepts already present for
`RCConstCon`/`RCConstClosure`:

```idris2
annotate natives owned e@(RV _ (RCConst _)) = pure e
annotate natives owned e@(RV _ (RCEmptyCon {})) = pure e
annotate natives owned e@(RV _ RCNull) = pure e
```

(`RC.idr:495-497`). This brings `annotate` in line with
`splitBorrows`/`dropIfLastUse`/`boxedOperands`'s `isBoxedOperand`
(`RC.idr:389-393`, `420-424`, `448-452`), which already excluded all
five constant forms uniformly from the start -- `annotate` itself was
the one place that had only special-cased 2 of the 5, because until
`RConCase` folding existed, only those 2 could ever reach it bare.

**Verification methodology**: found while building `RConCase`
folding, by compiling a repro exercising it and reading the resulting
C compile error directly (the failure mode here is a hard compile
error, not a silent miscompilation or leak, so it surfaced immediately
rather than needing valgrind or output diffing to catch). Confirmed
fixed by rebuilding with the three added intercepts and re-running the
same repro plus the full `rc2/tests/verify.sh` regression suite.

## The `noconstfold` directive

`--directive noconstfold` / `%cg rc2 noconstfold` disables the whole
`foldConstProgram` fixpoint pass (both halves -- CAF-boundary crossing
and `RConCase` scrutinee resolution live in the same `foldConst`
traversal, so there is no finer-grained toggle), following the exact
same `no<stagename>` pattern as `noinline`/`noconaltnative`/
`nomutualloop`/`noloop`/`nosink`/`nodualabi`/`nodeadcode`
(`RC2.idr:68-107`'s own module doc comment lists all of them together).
`Compiler.RC2.ConstExtPrim`'s own, separate fold (constant `ExtPrim`s
like `prim__codegen`) runs unconditionally inside `toRCDefPreFold` and
is *not* affected by this directive -- only the `ConstFold.idr`-driven
whole-program pass is gated:

```idris2
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
```

(`RC2.idr:157-159`). Skipping it, like every other stage in this list,
still produces correct (if less optimised) C -- nothing downstream
requires a CAF or a case scrutinee to have been folded away.

## Tests

Four new tests under `rc2/tests/`, three registered in
`rc2/tests/verify.sh`'s `LEAK_SENSITIVE_TESTS` (all but Test76, which
has nothing to leak-check -- its whole point is that folding never
happens):

- **`Test74ConstFoldCafBoundaryClosure`** -- a closure-shaped CAF
  (`dict : Pair; dict = MkPair op1 op2`) referenced only from a
  *separate* definition (`useDict`), never built inline inside `main`.
  This deliberately isolates the new whole-program `CafTable` from
  `Compiler.RC2.Inline`'s own constructor-only splicing side-channel
  (which reaches only a constructor-shaped CAF built at its own call
  site, see `const-con-fold.md`'s CAF-boundary discussion) -- if this
  folds, it's proof the new fixpoint loop did it, not `Inline`.
  Confirmed by hand via `--directive dumprcexpr`: `Main.useDict`'s own
  dump references `Main.dict` directly as a `RCConstCon`/
  `RCConstClosure` literal, never a `RAppName ... "Main.dict" []` call.
- **`Test75ConstFoldConCaseScrutinee`** -- `directCase`'s scrutinee is
  a known-constant `RCConstCon` bound by a `let` immediately above the
  `case`, so the whole case (tag dispatch included) must fold away to
  a single `RPrimVal`. `areaOf`'s own two calls keep a genuinely
  dynamic scrutinee (an ordinary function argument) to exercise the
  pass's required fallback (`RConCase` unchanged but for its own
  recursively-folded alts). This test's own passing, valgrind-clean
  run doubles as the informal confirmation that `Compiler.RC2.Reuse`'s
  reservation logic and `Emit.idr`'s own case-lowering handle a
  never-actually-destructured scrutinee correctly -- see "Scope /
  limitations" below.
- **`Test76ConstFoldMutualCafSafety`** -- a safety net, not a folding
  test: `a = More 1 b; b = More 2 a` are two CAFs that reference each
  other, so neither's `cafValueOf` ever stabilizes no matter how many
  fixpoint rounds run. The only thing checked is that
  `maxConstFoldIterations` bounds the loop and the program still
  compiles and runs normally (both CAFs left as ordinary, un-folded
  `RAppName` calls) instead of hanging the compiler or crashing.
  `sumFirst 3 a` is guarded behind a condition (`length args > 100`)
  that's always false with no CLI arguments, so it's never actually
  evaluated -- it exists purely to give `a`/`b` a live,
  statically-reachable use, so `Compiler.RC2.DeadCode` can't prune them
  away before `ConstFold` ever gets a chance to loop on them.
- **`Test77ConstFoldCafChainCap`** -- an off-by-one regression for
  `maxConstFoldIterations` itself: a 3-hop CAF alias chain over a
  2-field record (`capC = capB; capB = capA; capA = MkBox op1 0`, two
  fields specifically so the record isn't optimised away as a
  transparent single-field newtype, which would sidestep the CAF chain
  this test exists to exercise). Each hop only resolves once the CAF
  one step further down the chain has already been entered into
  `CafTable` by a *prior* round, so resolving the whole chain needs
  multiple rounds, not one. Confirmed by hand: with the cap at 4,
  `Main.capA`/`capB`/`capC` disappear from `--directive dumprcexpr`'s
  own output entirely (pruned by `Compiler.RC2.DeadCode` once nothing
  calls them by name any more), leaving `main` applying a single
  folded `RCConstClosure` directly.

## Scope / limitations

- **Still bounded by the 4-round cap.** A CAF chain deep enough to
  need a 5th round (or deeper) stays partially unfolded -- a missed
  optimisation, never a correctness issue, per the monotonicity
  argument above. `Test77ConstFoldCafChainCap` confirms the cap is at
  least high enough for a realistic short chain; it does not exercise
  the cap actually being hit.
- **`Compiler.RC2.Reuse`/`Emit.idr` audit**: `const-con-fold.md`'s own
  "Scope / limitations" section flagged that, once a `case` scrutinee
  folds away entirely, `Compiler.RC2.Reuse`'s reservation logic and
  `Emit.idr`'s own case-lowering -- both of which assume a scrutinee is
  a real, runtime-destructured heap `RCLoc` -- would need auditing for
  correct dup/drop bookkeeping. In practice this never becomes a live
  concern: once `RConCase`/`RConstCase` folds its scrutinee, the whole
  case node (scrutinee included) is replaced by the chosen alt's own
  body before either `Compiler.RC2.RC`'s annotation pass or
  `Compiler.RC2.Reuse` ever runs (`ConstFold` runs first in
  `toRCDefs`, `RC2.idr:152-165`) -- there is no surviving `RConCase`
  node left for either of those later passes to see, so there is
  nothing for them to mishandle. `Test75ConstFoldConCaseScrutinee`'s
  own valgrind-clean pass through `LEAK_SENSITIVE_TESTS` is the
  empirical confirmation of this, not a formal proof; no residual
  concern is currently open.
- The `RCrash "...matched no alt and had no default"` branches in
  `foldConst`'s own `RConCase` case are believed unreachable given
  upstream's own case-coverage checking (see "Design" above) -- kept
  for totality, not because a repro exercising them is expected to
  exist.

## Files

- `rc2/src/Compiler/RC2/ConstFold.idr` -- `CafTable`, `findConAlt`/
  `insertConArgs`, the `RAppName`/`RConCase` folding cases, `cafValueOf`.
- `rc2/src/Compiler/RC2/RC2.idr` -- `maxConstFoldIterations`,
  `foldConstProgram`, the `noconstfold` directive wiring in `toRCDefs`
  and its own module doc comment.
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate`'s three added intercepts
  (`RCConst`/`RCEmptyCon`/`RCNull`).
- `rc2/tests/verify.sh` -- `Test74`/`Test75`/`Test77` added to
  `LEAK_SENSITIVE_TESTS` (`Test76` deliberately excluded -- nothing
  folds in it to leak-check).
- `rc2/tests/Test74ConstFoldCafBoundaryClosure`,
  `rc2/tests/Test75ConstFoldConCaseScrutinee`,
  `rc2/tests/Test76ConstFoldMutualCafSafety`,
  `rc2/tests/Test77ConstFoldCafChainCap` -- the four new regression
  tests described above.

## Verification methodology

1. `--directive dumprcexpr` (see `rc2/doc/reading-the-ir.md`) on each
   new test, before and after the change, to confirm exactly what
   folded (a `RCConstCon`/`RCConstClosure` literal replacing a
   `RAppName` call; a `case` collapsing to its one surviving alt's
   body) rather than inferring it indirectly from program output.
2. Read the generated C directly to confirm the *absence* of what
   should no longer be there: no residual call to a folded CAF's own
   C function, no `idris2rc2_mkClosure`/constructor-allocation call for
   a folded dictionary, no runtime tag-dispatch `switch`/`if` for a
   `RConCase` whose scrutinee resolved at compile time.
3. Full `rc2/tests/verify.sh` (with valgrind) run: 101 passed, 0
   known, 0 failed, 0 bytes definitely lost across every
   `LEAK_SENSITIVE_TESTS` entry including the three new ones --
   `Test75ConstFoldConCaseScrutinee` in particular is the direct
   valgrind-based confirmation that a resolved-and-discarded
   `RConCase` scrutinee introduces no dup/drop bookkeeping error (see
   "Scope / limitations" above).
4. `Test76ConstFoldMutualCafSafety` (mutually-referencing CAFs) is
   itself a verification device for the fixpoint loop's own
   termination guarantee -- a wrong implementation of the cap or the
   change-detection logic would hang the compiler outright on this
   input, not just produce a wrong answer, so its own successful
   compile is the check.
5. If ever extending which node shapes participate in CAF-boundary or
   `RConCase` folding: bisect a new leak the same way
   `const-con-fold.md`'s own Bug #2 was found (a `git stash` against a
   pre-change build, rerun the identical repro under valgrind) --
   `annotate`'s missing-intercept bug this document describes was a
   hard compile error, not a leak, but nothing guarantees every future
   gap in this area will be caught that loudly.
