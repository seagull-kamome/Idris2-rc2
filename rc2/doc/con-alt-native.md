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
3. `core'` is `core` with only `fieldId`'s own *native-context*
   occurrences redirected to `shadowId` (`markNativeOccurrences`,
   mirroring `Loop.idr`'s own `nativeArgTypes`/`opNativeUsesThrough`
   walk exactly, but rewriting instead of collecting) -- any surviving
   Boxed-context occurrence is left on `fieldId` itself, untouched.
   `stripOwnership` (`Compiler.RC2.Loop`, reused directly) first clears
   whatever stale `RDup`/`RDrop`/`postDrop` bookkeeping `annotate` had
   attached to `fieldId` (computed back when every occurrence, native
   and Boxed alike, was still assumed to disappear into the shadow),
   then `reannotateFieldOwnership` rebuilds ownership for just
   `fieldId`, from scratch, over whatever Boxed-context occurrences
   remain -- see "Reusing the original Boxed field for surviving
   Boxed-context reads" below for the full design and the two real
   bugs found landing it.
4. A destructured field can still have a genuinely separate Boxed use
   in the same alt (`case acc of MkAcc x y => f x (show y)`) -- as of
   the design in point 3 above, that reference keeps referring to
   `fieldId` itself rather than being redirected to the shadow, so it
   keeps sharing the original field's own identity via an ordinary
   `dup`/move exactly as it would without this pass running at all,
   instead of paying for a fresh reallocation every time
   `rcVarToBoxedC` would otherwise have to re-box a still-Native
   shadow on demand.

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
   wrapper node (the same five shapes from "Design" above) first,
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

## Reusing the original Boxed field for surviving Boxed-context reads

Point 4 above used to mean an unconditional re-box: `rcVarToBoxedC`
allocating a fresh `IDRIS2RC2_Value*` from the shadow's own native
value every single time a Boxed-context read of the field survived
promotion, rather than sharing the identity the original, still-live
field already had (see `TODO.md`'s own "Performance: reboxing a
native-shadowed value always allocates fresh" entry for the full
motivation, and `rc2/doc/loop-conversion.md`'s "Native-shadow
promotion" section for where this trade-off was first accepted for
`Compiler.RC2.Loop`'s own, structurally similar case). Fixed here for
`ConAltNative` specifically (`Compiler.RC2.Loop`'s own loop-carried
shadow promotion is unaffected -- see that TODO entry for why the two
cases aren't the same problem) by splitting what used to be one
combined rename-and-strip step into three, run per promoted field
rather than batched:

1. `stripOwnership (singleton fieldId)` clears `fieldId`'s own stale
   ownership bookkeeping first, exactly as before, just keyed on the
   original field id rather than a whole batch of shadow ids.
2. `markNativeOccurrences` mirrors `Loop.idr`'s own `nativeArgTypes`/
   `opNativeUsesThrough` walk exactly, but rewrites the native-context
   occurrences it finds instead of collecting their types -- every
   Boxed-context occurrence is left on `fieldId` untouched.
3. `reannotateFieldOwnership` rebuilds ownership for `fieldId` alone,
   from scratch, over whatever Boxed-context occurrences remain: the
   same "first occurrence moves, later ones dup" rule `RC.idr`'s own
   `annotate`/`splitBorrows` use, and the same per-arm drop-if-unused
   handling `branchBody` uses for `RConCase`/`RConstCase`'s own alts --
   both re-derived here in a form specialised to tracking a single
   local (`owned : Bool`) rather than `RC.idr`'s own whole-set version,
   since `annotate` itself can't simply be re-run over `core` (its own
   `RCon` case unconditionally resets `reuseFrom` to `Nothing`, which
   would silently undo whatever `Compiler.RC2.Reuse` had already
   decided).

Two real, `valgrind`-silent bugs (both compiled, ran, and printed the
*correct* result while still leaking or, in the second case, actively
corrupting memory) were found landing this, both via
`tests/Test12ConAltNative.idr`'s own new `multiBoxedUse`/`branchingUse`
cases (see "Files" below):

1. **A `freeLocalsR` lookahead in the naive left-to-right version of
   `reannotateFieldOwnership`'s own `RLet` case saw a lie.** The first
   attempt threaded ownership straight through, `value` then `body`, in
   source order -- correct in total dup/drop *count*, but wrong in
   *timing*: whichever occurrence of `fieldId` happened to come first
   textually got the move, and a later one got the `dup` -- backwards
   from the one ordering that's actually safe. A `dup` exists to
   guarantee an extra reference *before* anything could free the
   object; getting the *first* live use to move the object's only
   reference and only *then* running a `dup` for a later use is, if
   that first callee happens to drop what it was moved once it's done
   with it, a `dup` reading already-freed memory. `multiBoxedUse`
   (`show x ++ ... ++ show x ++ ...`, `x` read Boxed twice) reproduces
   this shape directly. Fixed by restoring `RC.idr`'s own `annotate`
   ordering: whether `fieldId` is still needed *later*, in `body`, is
   decided via a `freeLocalsR` lookahead *before* `value` is ever
   processed (exactly RC.idr's own `borrowVal`), so a `dup` always
   lands ahead of the read it protects, never behind it -- with one
   necessary departure from `RC.idr`'s own shape: `body` here has
   already had every native-context occurrence of `fieldId` redirected
   away by `markNativeOccurrences`, so when the lookahead finds none in
   `body` at all, `value`'s own actual post-processing result is
   threaded through unchanged rather than recomputed from `owned` the
   way `RC.idr`'s own `borrowVal` shape assumes (which implicitly
   assumes `value` always resolves every occurrence it's handed -- true
   for `RC.idr` itself, not true here, where `value` can easily contain
   zero occurrences of `fieldId` at all).
2. **`RConCase`/`RConstCase`/`RCmpCase` returned the wrong ownership to
   their own caller, producing both a double-drop and a genuine
   use-after-free in the same test.** The first attempt returned
   whatever `owned` state was current *before* the branch (or, for
   `RConCase`/`RConstCase`, after only the scrutinee's own read) --
   ignoring that `finalizeBranch` (see below) leaves `fieldId`
   *provably* fully consumed on every single arm it processes, whether
   by dropping it (an arm that never touches it) or by moving/dup'ing
   it into whatever Boxed-context read that arm does find. `branchingUse`
   (`case x/y of` two arms, one reading the destructured field only
   natively, the other only in a Boxed context) reproduced both
   failure modes from this one bug at once: `shadowAltFields`'s own
   outer `RLet` wrapping, seeing the stale "still owned" ownership this
   case wrongly reported, added its own unconditional `RDrop` --
   double-dropping `fieldId` on the arm that had already dropped it
   itself, and turning the *other* arm's own already-live Boxed-context
   read into a read of a value some *other*, never-taken arm would have
   freed. Fixed by having all three cases return `False`
   unconditionally: past `finalizeBranch`, `fieldId` is spent no matter
   which arm runs, so there is never anything left for a caller to
   still own.

Re-verified after both fixes: `valgrind --leak-check=full` against
`tests/Test12ConAltNative.idr` (`step`'s own reuse-in-place case,
`repeatedRead`'s own field-read-three-times case, `mixedUse`'s own
native-and-Boxed-same-field case, `multiBoxedUse`'s own repeated-dup
case, `branchingUse`'s own asymmetric-branch case) reports `definitely
lost: 0 bytes in 0 blocks` (`800 bytes in 100 blocks still reachable`
-- exactly the immortal small-int cache, not a leak). Full refc-suite
(19/19), the entire `tests/Test*.idr` smoke-test matrix, and
`rc2/tests/bench.sh`'s own micro-benchmark suite all pass unaffected.

## Files

- `rc2/src/Compiler/RC2/ConAltNative.idr` (new) -- `peelWrappers`,
  `shadowAltFields`, `assignShadowIds`, the `applyConAltNativeExp`/
  `applyConAltNativeAlt`/etc. whole-tree walk, exported
  `applyConAltNative`; `markNativeOccurrences`/`renameOpArgsThrough`,
  `reannotateFieldOwnership`/`finalizeBranch`, `countDupsNeeded`/
  `wrapNDups` (the "Reusing the original Boxed field" design above).
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgTypes`/`nativeArgType`/
  `opNativeUsesThrough` (already `export`ed, reused unchanged --
  `markNativeOccurrences`/`renameOpArgsThrough` mirror their own walk
  exactly rather than calling them, since they rewrite instead of
  collecting) and `stripOwnership` (already `export`ed, reused
  unchanged -- an earlier attempt to extend it for `RReuseOffer`'s own
  `dupOnShared` was added then reverted, see bug #2 above; its own doc
  comment now notes why `Compiler.RC2.ConAltNative` never needs that).
- `rc2/src/Compiler/RC2/RC.idr` -- `splitBorrows`/`annotate`/
  `branchBody` (the "first occurrence moves, later ones dup" ownership
  rule `reannotateFieldOwnership`/`finalizeBranch` re-derive, specialised
  to a single local; not called directly -- `annotate`'s own `RCon`
  case unconditionally resets `reuseFrom`, which would undo
  `Compiler.RC2.Reuse`'s own decisions if re-run over `core`).
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring
  (`applyConAltNative` right after `applyReuse`, before
  `applyMutualLoop`).
- `rc2/rc2.ipkg` -- new module added to the `modules` list.
- `rc2/tests/Test12ConAltNative.idr` (new) -- `step` (reuse-in-place
  interaction), `repeatedRead` (a field read natively three times,
  confirms the caching itself), `mixedUse` (the same field read both
  natively and in Boxed context), `multiBoxedUse` (a field read
  natively twice and in a Boxed context twice -- the dup-ordering bug's
  own dedicated regression), `branchingUse` (the destructured field's
  own Boxed-context use appearing in only one of two nested branch
  arms -- the branch-ownership bug's own dedicated regression).

## Verification methodology

1. Build + regression baseline: see `CLAUDE.md`'s "Build & test" section
   (`idris2 --build rc2.ipkg`, then `tests/refc-suite/run.sh`, expect 19/19).
2. `tests/Test12ConAltNative.idr` is this feature's own canonical smoke
   test -- diff its output against real `idris2 --cg refc`'s own
   (byte-for-byte), and read `Main_step`'s own generated C directly:
   the field reads should be `int64_t var_N = idris2rc2_to_i64(var_M);`
   immediately followed by `idris2rc2_drop(var_M);`, positioned *after*
   any `RReuseOffer`-lowered `if (idris2rc2_isUnique(...))` block, never
   before it -- and that block's own `dup`s should stay conditional,
   inside its own `else` branch, exactly as they are with this whole
   pass's pipeline entry removed.
3. **A stdout diff alone can't catch a reference leak, an unbalanced
   dup, or a use-after-free** -- every bug found in this module so far
   compiled, ran, and printed the *correct* result regardless (see
   "Bugs found and fixed" and "Reusing the original Boxed field" above
   for four separate confirmed instances of exactly this). Any change
   to `ConAltNative.idr`, or to `Compiler.RC2.Reuse`'s own
   `resolveAlt`/`Compiler.RC2.Loop`'s own `stripOwnership`/`nativeArgTypes`
   (all reused or mirrored here), should be re-checked with `valgrind
   --leak-check=full` against `tests/Test12ConAltNative.idr` specifically
   (its own `step` runs 200k iterations, deliberately large enough that
   a per-iteration leak is unmistakable in the summary rather than lost
   in noise; `multiBoxedUse`/`branchingUse` are the dedicated regressions
   for the dup-ordering and branch-ownership bugs specifically) --
   expect `definitely lost: 0 bytes in 0 blocks`.
4. Before concluding a fix is correct, also re-run step 3 against the
   *baseline* with this pass disabled via `--directive noconaltnative`
   (`RC2.idr`'s own `toRCDefs`, see its doc comment -- no rebuild
   needed) -- confirms whether a leak (or its absence) is actually
   caused by this pass at all, not just present regardless (exactly how
   the two small pre-existing leaks noted above were told apart from
   this work's own bugs, back when this meant editing `toRCDefs` and
   rebuilding `idris2-rc2` by hand instead).
