# Constructor-destructured field native shadowing (`Compiler.RC2.ConAltNative`)

## The problem

Function-local native type inference (`doc/native-type-inference.md`)
decides a Rep for every `RLet`-bound local, based on the shape of the
value it's bound to (`Types.repOf`: `ROp`/`RPrimVal` propose `RNative`,
everything else stays `RBoxed`). A case-alternative's own destructured
fields never went through this at all: `Compiler.RC2.RC`'s own
`normalizeConAlt` binds each field as a bare fresh id with no `Rep`
of its own, and `Compiler.RC2.Emit`'s `emitConAltBody` unconditionally
declared every one of them `IDRIS2RC2_Value *` (Boxed) -- regardless of
how many alternatives the enclosing `RConCase` has, whether the
scrutinee's type is single- or multi-constructor, or how the field
itself gets used afterward.

This sounds worse than it actually was in practice: `rcVarToNativeC`
(the accessor an `ROp`'s own native-result operand rendering already
uses) already unboxes a still-Boxed local inline at each native-context
read (`nativeUnbox ty (...)`) -- so a destructured field read *exactly
once* in a native context was already effectively native, at the cost
of one inline unbox at that one read, with completely correct ownership
(the field's own `RDrop`, wherever `annotate` naturally placed it, was
always there and always correct). The actual, narrower gap: a field
read **more than once** in a native context repeats that unbox call at
every read instead of caching it once.

## Design: cache the read, don't touch the field's own ownership

The field's own Boxed declaration, and its own participation in
`Compiler.RC2.RC`'s `annotate` (ownership) and `Compiler.RC2.Reuse`'s
`resolveAlt` (constructor-reuse-in-place) -- both of which already
correctly handle it as an ordinary Boxed local -- are **never touched**.
This pass runs as a new step immediately after `Compiler.RC2.Reuse`
(see `RC2.idr`'s own `toRCDefs`), so both of those have already fully
resolved everything about the field by the time it runs, and it only
ever *adds* a wrapping `RLet`+`RDrop` pair around whatever
"core" computation was already there -- it never edits an existing
ownership node's own meaning, only (via `renameRCExp`, scoped to that
core) what a handful of them refer to.

For each `RConAlt`, for each destructured field found read as a native
operand consistently (`Types.nativeArgType`, the exact same
usage-scan `Compiler.RC2.Loop`'s own native-shadow-loop-param mechanism
already uses for a whole function's own top-level parameters -- reused
directly, not re-derived):

1. Mint a fresh shadow id.
2. Wrap the alt's own "core" (see below) in
   `RLet shadowId (RNative ty) (RV (RCLoc fieldId)) (RDrop [RCLoc fieldId] core')`
   -- a *manually*-assigned `Rep`, bypassing `Types.repOf`'s own "only
   `ROp`/`RPrimVal` propose Native" rule the same way
   `Compiler.RC2.Loop`'s own `declareLoopParam` and
   `Compiler.RC2.DualABI`'s own worker synthesis already do for a value
   they already know is safe to declare native. `Emit.idr`'s
   `declareLet` already handles an arbitrary-shaped `RNative` value via
   `declareNative`, and `emitNativeValue`'s own bare-`RV` case (added
   Stage 3b of the dual-ABI effort, `doc/dual-abi.md`) already renders
   exactly this shape -- no new Emit.idr work needed.
3. `core'` is `core` with **every** reference to `fieldId` (not just
   native-context ones -- `renameRCExp` renames uniformly) redirected
   to `shadowId`, then `Compiler.RC2.Loop`'s own `stripOwnership`
   (reused directly) removes whatever stale `RDup`/`RDrop`/`postDrop`
   bookkeeping `annotate` had attached to those now-renamed-away
   occurrences (its own now-invalid target is `shadowId`, since
   `renameRCExp` rewrote those too).
4. A destructured field can still have a genuinely separate Boxed use
   in the same alt (`case acc of MkAcc x y => f x (show y)`) --
   redirecting *that* reference to the shadow too, and re-boxing it on
   demand via `rcVarToBoxedC`'s own already-established `RNative` case,
   needs no special-casing: a fresh allocation instead of sharing the
   one the field used to hold, invisible to any Idris-level program
   (scalars have no observable identity), the same reasoning
   `doc/dual-abi.md`'s own `nativePromotionFor` write-up already relies
   on for the analogous `RLet` case.

### "Core": peeling past ownership/reuse wrappers first

The one genuine subtlety, and the source of the one real bug found
implementing this (see below): an alt's own body is not always the
"real" computation directly. `Compiler.RC2.RC`'s own `annotate` and
`Compiler.RC2.Reuse`'s own `resolveAlt` can both wrap it in a chain of
`RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer` nodes *first* --
most importantly, a **`RReuseOffer`**, whose own uniqueness check must
run *before* anything else touches the field's own lifetime. The
`RLet`+`RDrop` wrapping above is therefore inserted only around the
**"core"** past every leading node of those five shapes
(`ConAltNative.idr`'s own `peelWrappers`) -- the wrappers themselves,
and everything they carry (an `RReuseOffer`'s own `dupOnShared`
included), are left completely untouched, not even renamed into.

## Bugs found and fixed

1. **First attempt: excluded a native-promoted field from ownership
   tracking entirely, like a genuinely native `RLet` local -- leaked.**
   Tried changing `RConAlt`'s own `args` to `List (Int, Rep)`, excluding
   a native-Rep field from `annotate`'s own `owned` set and from
   `Compiler.RC2.Reuse`'s own `dupOnShared`, and declaring it by
   unboxing `sc->args[k]` directly at destructure time, discarding the
   Boxed pointer outright. Every field is still *physically* stored
   Boxed inside a constructor regardless of Rep (`sc->args[k]` is always
   `IDRIS2RC2_Value *`) -- unlike an `RLet`-bound native value, which
   genuinely has no Boxed source anywhere to release, a destructured
   field's own Boxed *origin* still needs exactly one
   `idris2rc2_drop` somewhere, or it leaks. Confirmed with `valgrind
   --leak-check=full` against `tests/Test12ConAltNative.idr`'s own
   `step` (destructures `Acc = MkAcc Int Int` and immediately
   reconstructs the same shape, deliberately chosen to also exercise
   `Compiler.RC2.Reuse`'s own constructor-reuse-in-place path): ~6.4MB
   definitely lost over 200k iterations, one full `idris2rc2_mkInt64`
   allocation leaked per iteration (the *previous* iteration's own
   reused-constructor field value, overwritten without ever being
   dropped, since excluding the field from `owned` deleted the only
   drop it would otherwise have gotten). Reverted in full; not fixed
   forward. See `TODO.md`'s own git history for the full first
   write-up.
2. **Second attempt (the mint-shadow-and-rename design above, first
   cut): wrapped the *whole* alt body, including a leading
   `RReuseOffer` -- leaked again, same test, same magnitude.** Reading
   the field and dropping it via the new shadow wrapping happened
   *before* `Compiler.RC2.Reuse`'s own uniqueness check had even run.
   `Compiler.RC2.Emit`'s own `branchBody` (`emitConAltBody`'s helper)
   unconditionally `idris2rc2_dup`s every one of an alt's own con-args
   whenever the body it's handed doesn't *structurally start with*
   `RReuseOffer` (its own `(Just _, RReuseOffer {}) => ...` case is the
   only one that skips that dup, deferring entirely to
   `RReuseOffer`'s own lowering instead -- see `branchBody`'s own doc
   comment for why). Wrapping the whole body in a new outer `RLet` broke
   that structural match: `branchBody` no longer recognised the (now
   nested, not outermost) `RReuseOffer`, so it unconditionally dup'd
   `var_1`/`var_2` regardless of which reuse path was actually taken,
   while the *real* `RReuseOffer` (further inside, past the new
   wrapping) went on to make its own, now-redundant, correctly
   *conditional* dup decision on top of that -- an extra, permanently
   unbalanced reference per reused field, per call. Confirmed leaking
   via the same `valgrind` test, then confirmed the *baseline*
   (`Compiler.RC2.ConAltNative` pipeline entry temporarily removed) was
   already leak-free with the identical dup pattern *correctly*
   conditional inside `RReuseOffer`'s own `else` branch -- proving the
   regression was this pass's own insertion point, not anything
   pre-existing. Fixed by `peelWrappers`: split off every leading
   `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer` node first,
   insert the shadow wrapping only around the "core" underneath, and
   rebuild by re-wrapping afterward -- the wrappers (and an
   `RReuseOffer`'s own `dupOnShared`) are never renamed into at all
   now, so the whole "does this exclusion actually matter" question
   this fix's own first draft agonised over (a `stripOwnership`
   extension to also filter `dupOnShared`, added then reverted) turned
   out moot: with the correct insertion point, `dupOnShared` is simply
   never touched by this pass in the first place.

Re-verified after the fix: `valgrind --leak-check=full` against
`tests/Test12ConAltNative.idr` (`step`'s own reuse-in-place case,
`repeatedRead`'s own field-read-three-times case, `mixedUse`'s own
native-and-Boxed-same-field case) reports `definitely lost: 0 bytes in
0 blocks` (`800 bytes in 100 blocks still reachable` -- exactly the
immortal small-int cache, not a leak). Full refc-suite (19/19) and the
entire `tests/Test*.idr` smoke-test matrix re-diffed byte-for-byte
against real `idris2 --cg refc`, unaffected. Two small, *pre-existing*
leaks found incidentally while re-running `valgrind` across the smoke
tests (`Test1Basics`: 96 bytes/5 blocks; `Test9SelfTailLoop`: 784
bytes/49 blocks) were confirmed present, identical in size, with this
whole pass's own pipeline entry removed entirely -- unrelated to this
work, not investigated further here.

## Files

- `rc2/src/Compiler/RC2/ConAltNative.idr` (new) -- `peelWrappers`,
  `shadowAltFields`, `assignShadowIds`, the `applyConAltNativeExp`/
  `applyConAltNativeAlt`/etc. whole-tree walk, exported `applyConAltNative`.
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgTypes`/`nativeArgType`
  (already `export`ed, reused unchanged) and `stripOwnership` (already
  `export`ed, reused unchanged -- an earlier attempt to extend it for
  `RReuseOffer`'s own `dupOnShared` was added then reverted, see bug #2
  above; its own doc comment now notes why `Compiler.RC2.ConAltNative`
  never needs that).
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring
  (`applyConAltNative` right after `applyReuse`, before
  `applyMutualLoop`).
- `rc2/rc2.ipkg` -- new module added to the `modules` list.
- `rc2/tests/Test12ConAltNative.idr` (new) -- `step` (reuse-in-place
  interaction), `repeatedRead` (a field read natively three times,
  confirms the caching itself), `mixedUse` (the same field read both
  natively and in Boxed context).

## Verification methodology

1. `cd rc2 && source ../env.sh && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'`
2. `cd tests/refc-suite && nix-shell -p gcc gmp pkg-config --run './run.sh'` -- expect 19/19.
3. `tests/Test12ConAltNative.idr` is this feature's own canonical smoke
   test -- diff its output against real `idris2 --cg refc`'s own
   (byte-for-byte), and read `Main_step`'s own generated C directly:
   the field reads should be `int64_t var_N = idris2rc2_to_i64(var_M);`
   immediately followed by `idris2rc2_drop(var_M);`, positioned *after*
   any `RReuseOffer`-lowered `if (idris2rc2_isUnique(...))` block, never
   before it -- and that block's own `dup`s should stay conditional,
   inside its own `else` branch, exactly as they are with this whole
   pass's pipeline entry removed.
4. **A stdout diff alone can't catch a reference leak or an unbalanced
   dup** -- both bugs above compiled, ran, and printed the *correct*
   result while still leaking. Any change to `ConAltNative.idr`, or to
   `Compiler.RC2.Reuse`'s own `resolveAlt`/`Compiler.RC2.Loop`'s own
   `stripOwnership` (both reused here), should be re-checked with
   `valgrind --leak-check=full` against `tests/Test12ConAltNative.idr`
   specifically (its own `step` runs 200k iterations, deliberately
   large enough that a per-iteration leak is unmistakable in the
   summary rather than lost in noise) -- expect `definitely lost: 0
   bytes in 0 blocks`.
5. Before concluding a fix is correct, also rebuild with this pass's
   own pipeline entry in `RC2.idr`'s `toRCDefs` temporarily removed and
   re-run step 4 against the *baseline* -- confirms whether a leak (or
   its absence) is actually caused by this pass at all, not just
   present regardless (exactly how the two small pre-existing leaks
   noted above were told apart from this work's own bugs).
