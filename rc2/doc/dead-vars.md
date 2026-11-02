# `Compiler.RC2.DeadVars`: erasing bindings nothing ever references

## Motivation

Looking at real `--directive dumprcexpr` output (`idris2-lsp`, a large
real-world program), a small, single-caller `Compiler.RC2.SpecClosure`
clone kept showing up alongside plenty of ordinary `RConAlt`s (a
`case` alternative's own destructured constructor fields) whose bound
variable was never read anywhere in that alternative's own body --
not used, not even dropped. Every such binding still costs something:
`Compiler.RC2.Emit` declares a real C local for it
(`IDRIS2RC2_Value *var_N = sc->args[k];`), and it's one more entry a
human reading a `dumprcexpr` dump has to mentally discard as noise.

Emitting the C declaration is a dead end for actually removing this,
though: nothing about it is visible to any earlier pass, or to the
dump itself, so it can never look any better than "one line of
generated C, once, right here" -- worth doing eventually, but the real
win is making the *IR* say "this field is never used," not just
skipping one declaration at the very last stage.

## What "never referenced" actually is

`RConAlt`'s own destructured fields (`MkRConAlt`'s `args : List Int`)
are plain variable ids, positionally aligned 1:1 with the matched
constructor's own real fields (`Compiler.RC2.Emit`'s `emitConAltBody`
indexes `sc->args[k]` by position, so an entry can't just be deleted
from the list without breaking every later field's own indexing).
"Never referenced" means `Compiler.RC2.RCExp.freeLocalsR` on that
alt's own body doesn't contain it at all -- and `freeLocalsR` already
counts an `RDrop`/`RFree`/`RReleaseReuse` target as a genuine
reference (unlike `Compiler.RC2.Sink`'s own, deliberately different,
`genuinelyUsedR`), so this is a strictly narrower, more conservative
notion than "unused" in the ordinary sense: a field this pass erases
is one nothing, anywhere, in the final body ever needs released
either.

## Why it's broader in practice than it first looked

The original guess was that this would only ever catch a
*native*-classified field (`Compiler.RC2.RC`'s own
`definitionNatives`, deliberately never drop-tracked at all) whose one
and only use got optimised away by some later pass -- reasoning that
every genuinely *Boxed* unused field already gets an explicit `RDrop`
from `annotate` (`Compiler.RC2.RC`'s own ownership annotation pass),
which would already count as a reference.

That undersold it. For an ordinary (non-reuse-eligible) match, what
actually reaches `Compiler.RC2.DeadVars` looks like this (a real
example, a 3-field record keeping only one field):

```
case v9453 of
  Prelude.Interfaces.MkApplicative [record] tag=Just 0 args=[v9455, v9457, v9456] ->
    dup v9457
    drop [v9453]
    apply v9457 [...]
```

The field actually kept (`v9457`) gets an explicit `dup`; the *whole*
scrutinee (`v9453`) gets one plain `drop` afterward, relying on that
drop's own recursive teardown to release every field never separately
`dup`'d -- `annotate`'s own synthesized per-field `RDrop` for the two
unused fields notwithstanding. Whichever later resolution produces
this shape doesn't need `annotate`'s own individual field references
to survive to `Emit` at all. So this pass ends up catching the
ordinary, ubiquitous "record pattern match, only using some of the
fields" case, not just the narrow native one originally motivating it.
Measured directly: compiling `idris2-lsp` with `--directive
dumprcexpr` erased over 19000 fields this way.

None of this affects correctness -- the `freeLocalsR` check doesn't
care *why* a field ended up unreferenced in the final body, only
whether it is -- just the estimate of how often it matters.

## Why `0`, not a structural "no binding" marker

`args : List Int` staying exactly that (rather than, say, `List
(Maybe Int)`) was a deliberate choice to keep this pass's own blast
radius small: `RConAlt.args` is threaded through essentially every
pass in the pipeline (`ConstFold`, `ConAltNative`, `DualABI`, `Sink`,
`Loop`/`MutualLoop`, `LateInline`, `SpecClosure`, `Reuse`, `Pretty`,
`DupMerge`), and the overwhelming majority of those sites only ever
thread `args` straight through unopened to keep recursing into the
alt's own body -- changing its type would force every one of those
call sites to at least re-typecheck, for no benefit, since none of
them need to know or care whether a given field has a real binding.

Reusing the plain `Int` domain instead needs exactly one program-wide
invariant to stay sound: `0` is never a genuine variable id anywhere.
`Compiler.RC2.Util`'s own shared `VarId` counter -- the single source
every fresh id in the whole pipeline is drawn from, `Compiler.RC2.RC`'s
own top-level parameters and `RConAlt` fields included -- now starts
at `1` instead of `0` specifically to guarantee this globally, with no
scan required.

## Why last, strictly after `Compiler.RC2.DupMerge`

Renaming preserves "is this id referenced anywhere" as a structural
property: if id `x` doesn't appear in `freeLocalsR body`, then after a
consistent whole-subtree rename `x -> y`, `y` doesn't appear in
`freeLocalsR` of the renamed body either. So a `0` placed by this pass
would stay behaviorally inert even if some later pass renamed it to a
fresh, "real-looking" id -- but there is no reason to rely on that.
Every pass that renames or freshens a variable id anywhere
(`Compiler.RC2.Loop`/`MutualLoop`'s own tail-loop conversion,
`Compiler.RC2.LateInline`'s splicing, `Compiler.RC2.SpecClosure`'s
cloning, `Compiler.RC2.DualABI`'s worker/wrapper split) runs strictly
before this pass, so `0` is placed once, by this pass alone, and never
touched again before `Compiler.RC2.Emit` consumes it. Disable with
`--directive nodeadvars`.

## What `Emit.idr` does with it

`emitConAltBody`'s own per-field loop skips the C declaration entirely
for a `0` entry -- nothing anywhere in the alt's own body could
possibly reference it, that's exactly what earned it the `0` in the
first place -- while still incrementing its own running field-index
counter for it, since it's still real storage at that offset in the
matched constructor, just not one this alt itself ever needs to name.

- Measured on idris2-lsp: asking per alt (`freeLocalsR` of the alt's own body) cost 2.74s of the pass's 2.82s; the single whole-definition `mentionedLocals` set replaces it.

## Constant aliases

The pass also removes `let x = <constant>`. `LateInline` binds a callee's
parameter to a fresh variable when the argument is a constant, because its
`Renaming` maps ids to ids and cannot name a constant (`buildSplice`, last
clause). The callee's own `dup`s and `drop`s of the parameter then stay, on a
variable bound to something that is NULL, an immediate or an immortal static.
`ConstFold`, `SpecConstCon`, `SpecClosure` and `ArityRaise` leave a few of the
same shape. Counted on `TestAsyncHTTPServer`, stopping `LateInline` removes 87%
of them.

`propagateConstAliases` runs before the erasure above, on each definition:

- It takes every `RLet x _ (RV c)` whose `c` is NULL, erased, the world, an
  empty or constant constructor, a constant closure, a string, or an
  integer, character or `Bits` literal that is an immediate. A `Double`, an
  `Int64` or `Integer` outside [-2^62, 2^62) and a `Bits64` of 2^63 or more
  are left: `rcVarToBoxedC` boxes such a native literal with a fresh
  allocation at every read, so a variable bound to one owns a cell and keeps
  its `dup`s and `drop`s (`safeConst`). A `let` that holds a pointer natively
  (`Native Ptr`) is left too: boxing one gives the tagged word `mkPtr` makes,
  and a null pointer read that way is not the plain `NULL` of `RCNull`, which
  `idris2rc2_toPtr` would then dereference (`plainRep`). A `let` binding the same id twice is left
  as well.
- `x` stays when a node reads it where a variable is needed: a `case`
  scrutinee, a cell or struct, a forced or applied value, a reuse token, or a
  `reuse=`. A loop parameter has the same id as the variable that starts the
  loop, so that id stays too; replacing it would turn the reads inside the loop
  into the constant (`Test155ConstAlias`, `countVowels`).
- Every other read of `x` becomes `c`, the `let` is removed, and so are the
  `dup`, `drop` and `free` of `x` and the constants in `postDrop` lists, which
  `Emit` reads as variables.
- It repeats up to three times, since replacing one alias can make another
  `let` a constant.

Disable with `--directive noconstalias`; `--directive nodeadvars` turns off
the whole pass.

Measured on `TestAsyncHTTPServer`: the `let`s that bind a constant go from 84
to 15 of 2,944, the `dup`/`drop` lines from 2,294 to 2,266.
