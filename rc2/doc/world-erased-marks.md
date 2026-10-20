# Erased values and the world token in the IR

Written when the "mark `World`/`Erased` on IR variables" task was closed
(2026-10-20). What was built, what was measured, and why the rest was
dropped, so nobody re-derives it.

## The problem

`ArityRaise` (`doc/world-arity-raising.md`) must not raise a function that
already took the world as a parameter and returns an `IO` action as its
result. The IR has no types, so `worldInPrefix` guesses from how the last
parameter is used in the prefix of the body. Its known costs: a hole (a
world held in a partial application that the prefix then applies) and fewer
raises than could be done (`TestTask`: 11/16 -> 6/15). The idea was to mark
variables and parameters that are the world, or erased, and use the marks
instead of the guess.

## What was built

- `RCLocal` has `RCErased` (`[erased]`) and `RCWorld` (`[world]`), apart
  from `RCNull` (`[__]`: nullary constructors, loop-slot padding). All are
  C `NULL`. `NmErased` and `NmPrimVal WorldVal` become them in `bindOne`.
- The world token is always `NULL` at run time: `idris2rc2_freshWorld` is
  gone and `main` is called with `NULL`. So a variable known to be the world
  can be replaced by `[world]` whatever its callers pass.
- A `let` bound to an erased value or the world token joins the no-refcount
  set in `RC.alwaysUnboxedBoxedLocalsR`; `DupMerge.nativeBound` lists it as
  `nullBoundKey` (a negated id) so `readsOnly` treats its operand as read
  only while `renameAliasDrop` still skips only native locals. Over the
  smoke tests' IR dumps `dup` fell 3679 -> 2732.
- `ConstFold` folds such a `let` into its readers like `RCConstCon`; the
  `let` goes once nothing reads it. Dumps: 73478 -> 73227 lines, standalone
  `[erased]/[world]/[__]` lines 469 -> 375. A loop's parameter ids equal
  its initial lets' ids, so those lets stay.
- `rc2base`'s dump parser reads `[erased]` and `[world]` as `RNull`.

## What was measured and dropped

Marking function **parameters** was tried and not kept.

- **Backward from `%foreign`.** A parameter that reaches a `CFWorld` slot of
  a `%foreign` declaration (propagated through named calls, four rounds) is
  the world, and that holds for functions that escape too. Over 56 test
  compiles it marked the last parameter of 383 functions. None of the 16
  functions `ArityRaise` raised was marked (no soundness signal), and none
  of the 4 that only `worldInPrefix` keeps from being raised
  (`Test128ArityRaiseWorldParam`) was: their world only reaches an `apply`
  of an unknown closure.
- **Forward from callers.** "Every caller passes `[world]`/`[erased]`" is
  sound only for a function that does not escape (a polymorphic `a` can
  receive `[erased]` from every known caller and a real value from a
  closure caller), and a world is passed on as the caller's own parameter,
  not as a constant.
- **Declared types.** `GlobalDef.type` is reachable through `Ref Ctxt Defs`,
  and `IO a` unfolds to `%World -> IORes a`. But `CLam`/`NmLam` carry no
  binder type and rc2 gets no source terms, so only declared functions
  would be covered. The 4 functions above are lambdas lifted from
  `\env, done, world => ...`, with no `GlobalDef`; `idris2-src/` cannot be
  changed, so carrying binder types would mean rewriting `toCExpTm` in rc2.
- **Binder names.** `MN "world" n` is made in one place only,
  `Compiler/Inline.idr:167` (`genName "world"` in the `io_bind` special
  case), so such a binder is the world. The name survives to
  `RC.lift`, but rc2's own `InlineCExp.copy` renames every binder to
  `rc2inl:N`, which is where the 4 functions lost it. Keeping the class in
  that rename (a base name `rc2inlworld`) restored a world-named last
  binder on 3 of the 4. The fourth is not world-named even before
  inlining; it may be a function `worldInPrefix` keeps wrongly.
- **Why it stops here.** A name proves "is the world", never "is not". A
  mark can only add functions to the skipped set, so it could close the
  hole but cannot recover the lost raises, and no test shows the hole.
  Dropping `worldInPrefix` needs the opposite proof, which none of the
  sources gives. Parameter marks would also touch at most about 8% of the
  `dup`s (those of a function's last parameter).

## If it is picked up again

- Close the hole only: keep the world class in `InlineCExp.copy`, record at
  lowering the functions whose last binder is world-named (a name table
  consumed by `ArityRaise`; a clone that loses its name falls back to the
  guess, so a lost mark is safe), and skip them. First find a program that
  shows the hole.
- Recover the lost raises: needs completeness, i.e. a source of "this
  parameter is not the world". That means binder types out of the term to
  `CExp` translation.
