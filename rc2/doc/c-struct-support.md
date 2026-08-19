# C struct FFI support (`System.FFI.Struct`/`getField`/`setField`): design proposed, not yet implemented

Upstream Idris2's `System.FFI` module (`idris2-src/libs/base/System/FFI.idr`)
provides direct access to C structs via `Struct`/`getField`/`setField`
(backed by the `prim__getField`/`prim__setField` ExtPrims), plus
struct-by-value `%foreign` arguments/returns (`CFStruct` in
`Core.CompileExpr`). The Chez backend fully supports both. RefC does
not -- and rc2, having copied RefC's own ExtPrim whitelist and
`extractValue`/`packCFType` verbatim, inherited the identical gap. This
document records what's been confirmed, what upstream's own issue
tracker already says about this gap, and a concrete design ("Design:
dedicated `RStructGet`/`RStructSet` nodes, resolved in `Emit.idr`"
below) -- verified against actual `RCExp`/generated-C output, not just
constructor shapes. No implementation has started yet.

## What's confirmed

**`getField`/`setField` compile cleanly but fail at the C-compile
step, not just "in theory".** RefC and rc2 both accept
`prim__getField`/`prim__setField` as "known" ExtPrims (`RefC.idr`'s own
`prims` whitelist in `cStatementsFromANF`'s `AExtPrim` case;
`Emit.idr`'s identical whitelist in `emitRC`'s `RExtPrim` case) and
lower a call to it verbatim (`idris2_prim__getField(...)` /
`idris2rc2_prim__getField(...)`) -- but neither `support/refc/` nor
`rc2/support/rc2/` defines that function anywhere. Reproduced by hand:

```idris2
module Main
import System.FFI

main : IO ()
main = do
  ptr <- malloc 16
  let s : Struct "my_struct" [("x", Int), ("y", Double)] = believe_me ptr
  let v = the Int (getField s "x")
  printLn v
```

compiles through `idris2 --cg refc` without error, but the generated C
fails at the C-compile step:

```
build/exec/t.c: In function ‘Main_main’:
build/exec/t.c:310:22: error: implicit declaration of function
  ‘idris2_System_FFI_prim__getField’ [-Wimplicit-function-declaration]
  310 |     Value * var_13 = idris2_System_FFI_prim__getField(var_14, NULL, NULL, var_1, var_15, var_16);
```

rc2's own `Emit.idr` would produce the analogous
`idris2rc2_System_FFI_prim__getField(...)` call, equally undefined.

**Struct-by-value FFI (`CFStruct` as a `%foreign` arg/return type) is
explicitly unimplemented, in both RefC and rc2.** `Emit.idr`'s own
`extractValue (CFStruct x xs) varName = idris_crash "INTERNAL ERROR:
Struct access not implemented: ..."` (`Emit.idr:2295`) -- copied
verbatim from upstream `RefC.idr:763`'s identical crash. `packCFType`'s
own `CFStruct` case (`Emit.idr:2319`) emits a call to a `makeStruct(...)`
helper that doesn't exist in `rc2/support/rc2/` either (mirrors
upstream RefC.idr:788, same status there).

**Field type information is erased by the time `getField`/`setField`
reach ANF/RCExp.** `prim__getField : {s : _} -> forall fs, ty . Struct s
fs -> (n : String) -> FieldType n ty fs -> ty` has two type-level
arguments (the field list `fs`, the result type `ty`) alongside the
struct name `s` and field name `n`. In the generated C call above,
those two show up as literal `NULL` (`idris2_..._prim__getField(var_14,
NULL, NULL, var_1, var_15, var_16)`) -- confirmed by reading the actual
generated code, not inferred. Only the struct name and field name
survive, as string literals (`var_15`/`var_16` in the example, actual
`Str` constants). **Any implementation has to resolve a field's C type
purely from those two strings, at compile time** -- there is nothing
usable in the runtime call itself.

**Chez doesn't solve that resolution problem at the call site either --
it defers it to Chez Scheme's own FFI type system.**
`Compiler/Scheme/Chez.idr`'s `mkStruct` walks every `%foreign`
signature's argument/return `CFType`s; the first time a given struct
name (`CFStruct n flds`) is seen, it emits `(define-ftype n (struct
[fld1 ty1] [fld2 ty2] ...))` and records `n` in a `Structs` ref so it's
only defined once. `chezExtPrim`'s `GetField`/`SetField` cases then
just emit `(ftype-ref n (fld) structPtr)` / `(ftype-set! n (fld)
structPtr val)` -- Chez Scheme's own `ftype-ref`/`ftype-set!` resolve
the field's type and offset from the `define-ftype` already registered
under that name, at macro-expansion time. **Struct field type
information only ever flows into a backend via a `%foreign` signature
that mentions `Struct`/`CFStruct`** -- a bare `getField`/`setField`
call site carries none of it, by itself.

## How struct field types actually appear in `Lifted`

Traced both sides of the split above directly in the compiler source,
confirming the "only via `%foreign`" claim precisely rather than just
inferring it from Chez's behaviour:

- **`%foreign` defs keep full `CFType` information, untouched, all the
  way through `Lifted`.** `LiftedDef`'s own foreign-def constructor
  (`idris2-src/src/Compiler/LambdaLift.idr:249`) is `MkLForeign : (ccs
  : List String) -> (fargs : List CFType) -> (ret : CFType) ->
  LiftedDef` -- the exact `CFType`s from the `%foreign` signature
  (`CFStruct n flds` included, with `flds`'s own field names/types
  intact) are carried as data on this constructor, never erased. rc2
  mirrors this exactly: `RCExp.idr`'s `MkRCForeign : (ccs : List
  String) -> (fargs : List CFType) -> CFType -> RCDef`, and
  `RC.idr:244`'s `normalizeDef (MkLForeign ccs fargs ret) = pure $
  MkRCForeign ccs fargs ret` is a straight, unmodified copy -- no
  information is lost converting `Lifted` -> `RCExp` here.
- **An ordinary call site (`getField`/`setField`, or any other
  `ExtPrim`) carries no type information at all, by construction.**
  `Lifted`'s own `LExtPrim` constructor
  (`idris2-src/src/Compiler/LambdaLift.idr:128`) is `LExtPrim : FC ->
  (lazy : Maybe LazyReason) -> (p : Name) -> (args : List (Lifted
  vars)) -> Lifted vars` -- just a primitive name and a list of value
  expressions, no `CFType` slot anywhere in the constructor itself.
  This is exactly why `prim__getField`'s own two type-level arguments
  (`fs`, `ty`) show up as runtime `NULL`s in the generated C (see
  above): there was never anywhere in `LExtPrim`'s own shape for that
  information to live once erasure ran, all the way back at the
  `Lifted` stage, well before rc2's own `RC.idr` (`normalizeDef
  (LExtPrim fc lazy p args) = ...`, a direct structural mirror of
  `MkLForeign`'s handling, no special-casing for any particular `p`)
  ever sees it.
- **Consequence for rc2's own pipeline:** `Compiler.RC2.RC2`'s
  `toRCDefs` (`RC2.idr`) processes each `RCDef` independently -- there
  is currently no pass, anywhere in the pipeline, that looks across
  every `MkRCForeign` in a compilation unit to build a name-indexed
  table the way Chez's `Structs` ref does. Any `getField`/`setField`
  implementation needs exactly that: a **first pass over every
  `MkRCForeign` in the whole compiled program**, collecting every
  `CFStruct n flds` seen (by struct name `n`) into a table, *before* a
  **second pass** that can resolve a `getField`/`setField` call site's
  struct-name/field-name string literals against it. This is a
  different shape from most optimization passes rc2 has today (which
  transform one `RCDef` at a time, independently) -- but it's exactly
  the shape `Compiler.RC2.Inline` already establishes: `buildEligible
  lds : SortedMap Name Eligible` scans every definition once to build a
  lookup table, then `applyInlineLifted lds = traverse (inlineDef
  (buildEligible lds)) lds` traverses the whole program again using
  it. A struct-field table would follow the identical two-step shape,
  just keyed on struct name (a `String`, from `CFStruct`) instead of
  `Name`.

## A concrete example, from `--dumplifted`

Upstream Idris2 has a `--dumplifted <file>` debug flag
(`idris2-src/src/Idris/CommandLine.idr:140`, wired through
`Compiler/Common.idr`) that dumps exactly the `LiftedDef`s described
above, as text, before any backend touches them. Ran it by hand on:

```idris2
module Main
import System.FFI

%foreign "C:make_point,point"
prim__makePoint : Int -> Double -> PrimIO (Struct "point" [("x", Int), ("y", Double)])

%foreign "C:point_free,point"
prim__pointFree : Struct "point" [("x", Int), ("y", Double)] -> PrimIO ()

makePoint : HasIO io => Int -> Double -> io (Struct "point" [("x", Int), ("y", Double)])
makePoint x y = primIO (prim__makePoint x y)

getX : Struct "point" [("x", Int), ("y", Double)] -> Int
getX s = getField s "x"

setY : HasIO io => Struct "point" [("x", Int), ("y", Double)] -> Double -> io ()
setY s v = liftIO (setField s "y" v)
```

(`idris2 --dumplifted lifted.txt --cg chez -o t T.idr`). The relevant
lines:

```
Main.prim__makePoint = Foreign call ["C:make_point,point"]
    [Int, Double, %World] -> IORes struct "point" ("x", Int) ("y", Double)

Main.prim__pointFree = Foreign call ["C:point_free,point"]
    [struct "point" ("x", Int) ("y", Double), %World] -> IORes Unit

Main.getX = [{arg:0}][]:
    %extprim System.FFI.prim__getField("point", ___, ___, !{arg:0}, "x", 0)

Main.{setY:0} = [{arg:2}, {arg:3}][{eta:0}]:
    %extprim System.FFI.prim__setField("point", ___, ___, !{arg:2}, "y", 1, !{arg:3}, !{eta:0})
```

This matches the two claims above exactly: the two `MkLForeign` entries
carry the full `struct "point" ("x", Int) ("y", Double)` shape (this is
`CFStruct`'s own `Show` output -- field names and types both intact);
the two `LExtPrim` call sites carry only the struct/field name string
literals (`"point"`, `"x"`/`"y"`) plus two `___` placeholders where
`fs`/`ty` used to be.

**A side discovery worth recording so a future session doesn't have to
re-derive it: the trailing `0`/`1` in each `LExtPrim` call is not
another erased placeholder -- it's the `FieldType` proof
(`fieldok`), collapsed to a plain integer.** `FieldType n t fs`
(`System/FFI.idr:19`) has exactly the shape Idris2's frontend
recognizes as "nat-like" (`TTImp/ProcessData.idr`'s `calcNaty`, driven
by `Core/CompileExpr.idr`'s `ConInfo`'s `ZERO`/`SUCC` tags -- not a
`Nat`-specific hack, a general structural check: two constructors, one
zero-arg, the other's one argument recursing into the same type
constructor): `First : FieldType n t ((n, t) :: ts)` (zero args) plays
`ZERO`, `Later : FieldType n t ts -> FieldType n t (f :: ts)` (one
recursive arg) plays `SUCC`. So a `FieldType` proof lowers to a plain
integer the same way a literal `Nat` does -- concretely, the zero-based
position of the field within the struct's own field list (`"x"` is
field 0 -> `First` -> `0`; `"y"` is field 1 -> `Later First` -> `1`).

This position integer isn't something a `getField`/`setField`
implementation needs to rely on -- Chez's own `chezExtPrim` ignores it
outright (`GetField`'s own pattern match ends in a bare `_`), resolving
purely from the struct-name/field-name string literals instead, and
any rc2 design should do the same (a field's *position* alone doesn't
carry its *type*, which is still only recoverable from the `CFStruct`
table described above). Recorded here only because it was an
unexplained `0`/`1` in the dump that turned out to have a real,
traceable explanation rather than being arbitrary.

## What upstream Idris2's own issue tracker says

Searched `idris-lang/Idris2`'s own issues for prior art before
designing anything, on the chance someone had already hit this wall.
They had -- and one of them ran into exactly the same problem this
document's "How struct field types actually appear in `Lifted`"
section derived independently, then gave up on it.

- **[#3830](https://github.com/idris-lang/Idris2/issues/3830)**
  (opened 2026-08-09, still open, no comments): reports the exact
  crash reproduced above -- `idris2 --cg refc` on upstream's own
  `samples/ffi/Struct.idr` hits `ERROR: INTERNAL ERROR: Struct access
  not implemented: var_1`, traced to the same `extractValue`
  `idris_crash` in `RefC.idr:763` this document already cites.
  Confirms the gap is real, currently unfixed upstream, and not
  something specific to how this investigation's own repro was
  written.
- **[#2062 "Align FFI with C FFI"](https://github.com/idris-lang/Idris2/issues/2062)**
  (opened 2021-11-22, closed 2022-07-21, discussion continued as late
  as 2026-08-31): the most directly relevant find. User `xavierzwirtz`
  tried to implement `getField` support for the RefC backend and,
  five months in, wrote:
  > The compiler currently computes a `CFType` only for `MkForeign`,
  > the `CFType` does not get attached to the return type of
  > `MkForeign` in a usable fashion. I believe that for
  > `prim__getField` to work `CFType` needs to be attached to the
  > expression so that when compiling an application of
  > `prim__getField` the accessed field's `CFType` can be used to
  > call `packCFType` and pack it for the RefC runtime. Tldr, how do
  > I get `CFType` for an arbitrary expression from within the refc
  > backend?

  Nobody answered. Six months after that, asked directly "how did you
  solve this," he replied: **"I cut bait and moved on. The memory
  model of Idris as it stands does not align well with passing by
  struct."** This is independent confirmation, from someone who
  actually tried, of the exact gap this document's own `Lifted`
  tracing found -- `CFType` info dies at any `LExtPrim` call site.

  **Where this document's own plan differs from what he was looking
  for** (and why it might succeed where he didn't): xavierzwirtz was
  after a way to recover a `CFType` for *an arbitrary expression* --
  a fully general mechanism. Nothing in his comments suggests he
  considered the narrower approach this document proposes: don't
  recover a type from the expression at all, resolve the
  struct-name/field-name *string literals* (which do survive to the
  call site, confirmed above) against a table built once from every
  `%foreign` signature's own `CFStruct` -- exactly what Chez's
  `Structs`/`mkStruct` already does, and what he'd have been re-deriving
  from Chez's own approach rather than solving generally from
  scratch. Worth staying alert to the possibility that this narrower
  path is exactly why he didn't find it -- he may have been solving a
  harder problem than the one that's actually needed.
- **[#1916 "Add support for value structs"](https://github.com/idris-lang/Idris2/issues/1916)**
  (2021, closed in favor of #2062): about *struct-by-value* FFI
  (Chez's `(& ftype)` vs. `(* ftype)`), a different and harder problem
  than pointer-based `getField`/`setField` -- not this document's
  scope, but the discussion that produced #2062 above.
- **[#36 "Nested Structs in FFI not read correctly"](https://github.com/idris-lang/Idris2/issues/36)**
  (2020, still open): a *Chez-specific* bug -- a struct field that is
  itself a struct *by value* (not `Ptr`) reads wrong values, because
  `Struct` is implicitly assumed to be a pointer everywhere, including
  in a `define-ftype`'s own field list, with (per maintainer `edwinb`'s
  own comment) no way to express the distinction to Chez Scheme. Out
  of scope for a first rc2 implementation (scalar fields only), but a
  real prior bug to be aware of if nested-struct fields are ever
  supported -- and notably a bug rc2 might sidestep for free, since it
  would emit a real C `typedef struct` rather than a Scheme `ftype`
  the way Chez does, and C itself doesn't share this pointer/value
  ambiguity.
- **[#3809 "FFI improvements (explicit Ptr) and additions (Union type and nested data fields)"](https://github.com/idris-lang/Idris2/issues/3809)**
  (opened 2026-07-08, open, no comments yet): a recent, more ambitious
  proposal -- explicit `Ptr` on pointer `Struct`s, nested-field access
  paths, non-pointer struct fields, and `union` support -- with a Chez
  backend PR reportedly attached. Well beyond this document's scope
  (basic scalar-field `getField`/`setField`), but worth knowing about
  as a direction upstream's own `System.FFI` module may move in.

## Design: dedicated `RStructGet`/`RStructSet` nodes, resolved in `Emit.idr`

An earlier draft of this design kept `getField`/`setField` as plain
`RExtPrim` calls all the way to `Emit.idr`, special-cased only there.
Current direction, decided after finding the ownership gap below:
convert `prim__getField`/`prim__setField` into two new, dedicated
`RCExp` nodes early (`Compiler.RC2.RC`'s own `normalize`, Phase 1), and
resolve *those* against the struct-field table in `Emit.idr`, instead
of pattern-matching `RExtPrim`'s own generic `args : List RCLocal`
shape at emission time. Struct-name/field-name stay plain `String`s on
the new nodes -- resolving them against a whole-program table stays
exactly where the earlier draft put it (`Emit.idr`'s own
`generateCSourceFile`); only *which node* carries them to that table
changes.

### Why a dedicated node instead of lowering `RExtPrim` directly

Two facts, confirmed by actually compiling a struct-using program with
rc2 and reading both the `RCExp` dump and `RC.idr`'s own source (not
assumed from constructor shapes alone):

1. A `getField`/`setField` call site's struct-name and field-name
   arguments are `RCConst (Str ...)` in `RCExp` itself, not something
   staged behind a runtime lookup -- directly pattern-matchable at
   compile time, no extra plumbing needed to recover them (unchanged
   from the earlier draft, still true).
2. **`RExtPrim` doesn't actually get the same ownership treatment as
   every other operand-consuming node.** `RAppName`/`RUnderApp`/
   `RApp`/`RCon`/`ROp`'s own `annotate` (Phase 2, `RC.idr`) cases all
   go through the same `wrapDups fc (splitBorrows natives owned args)
   (...)` pattern -- `splitBorrows` walks `args` against the current
   `owned` set, leaving still-alive operands to be `dup`'d
   (`wrapDups`) and letting operands used for the last time transfer
   ownership as-is. `RExtPrim`'s own case, by contrast
   (`annotate natives owned (RExtPrim fc lazy p args) = pure $ RExtPrim
   fc lazy p args`, `RC.idr:504`), is a bare pass-through -- no
   `splitBorrows`, no `wrapDups`, `owned` doesn't even get consulted.

   Confirmed by compiling the worked example above through rc2 itself
   (`--directive dumprcexpr`, `idris2-rc2 --cg rc2`) and reading what
   `annotate` actually decided, rather than assuming:

   ```
   def Main.getX  (fun args=["v0:Boxed"] ret=Boxed)
     extprim System.FFI.prim__getField [#"point", [__], [__], v0, #"x", #0]
   ```

   No `RDrop`/`RDup` wraps `v0` anywhere in `getX`'s own body -- it
   reaches the `extprim` call with no wrapping at all, which happens to
   be *correct* for a struct pointer used exactly once (this is the
   only use, so passing it as-is, ownership and all, is right) -- but
   nothing about `RExtPrim`'s own `annotate` case would keep computing
   the right answer if the same struct pointer were read by two
   `getField` calls in the same function: with `owned` never consulted,
   the second call would receive an already-consumed reference. This
   isn't a bug this document needs to fix generally (every current
   `RExtPrim` user -- `prim__newIORef`, array prims, etc. -- happens to
   only ever appear in a tail/single-use position in practice), but it
   means `RExtPrim`'s existing ownership handling isn't something a
   new, potentially-multiply-used struct accessor should inherit as-is.

A dedicated node sidesteps this by reusing `ROp`'s own proven pattern
instead of `RExtPrim`'s: same `wrapDups (splitBorrowsV natives owned
args) (...)` shape `ROp`'s own `annotate` case already uses
(`RC.idr:501-503`), applied to the new node's own operand(s). This also
leaves the door open for later passes (`Compiler.RC2.Sink`,
`Compiler.RC2.Loop`'s loop-invariant hoisting) to recognize a struct
field read/write as a first-class IR shape instead of an opaque
`RExtPrim` call, the same way they already recognize `ROp`/`RCon` --
though no such extension is designed or scoped here, just left
possible rather than foreclosed.

### The new nodes

```idris2
||| A read of one field out of a C struct pointer. structName/fieldName
||| stay plain strings -- resolved against a whole-program struct-field
||| table built once in Emit.idr's own generateCSourceFile (see "The
||| collection-and-lowering pass" below), the same way RPrimVal's own
||| dyngen/orStagen resolve a literal's concrete C rendering late,
||| rather than being pre-resolved to a CFType here. postDrop mirrors
||| ROp's own field (Compiler.RC2.RC's annotate, Phase 2) -- see
||| doc/native-type-inference.md's "What's stored on the IR vs.
||| re-derived" for why.
RStructGet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (postDrop : List RCLocal) -> RCExp

||| A write of one field into a C struct pointer, evaluating to Unit.
||| Same string-stays-unresolved reasoning as RStructGet.
RStructSet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (value : RCLocal) ->
             (postDrop : List RCLocal) -> RCExp
```

Both are shaped like `ROp` deliberately (an operand vector conceptually
-- `structVar` alone for `RStructGet`, `[structVar, value]` for
`RStructSet` -- plus a `postDrop` field Phase 2 fills in), so every
place that already knows how to treat an `ROp` node (`freeLocalsR`/
`countUsesR`/`usedConstructorsR` in `RCExp.idr`, `Compiler.RC2.Reuse`,
`Compiler.RC2.Sink`'s `consumedOperands`, `Compiler.RC2.Loop`'s
`stripOwnership`) gets a close structural precedent to copy rather than
inventing a new pattern -- this document doesn't attempt to enumerate
every one of those sites' own required changes yet (that's
implementation work, not design), but the *shape* to add is `ROp`'s own
shape, not a novel one.

### Phase 1 (`normalize`): converting `LExtPrim`/`RExtPrim` to the new nodes

In `Compiler.RC2.RC`'s `normalize`, add a case ahead of the generic
`LExtPrim fc lazy p args => bindMany env args (\locs => pure $ RExtPrim
fc lazy p locs)` (`RC.idr:163-164`) matching `p`'s name against
`prim__getField`/`prim__setField` specifically. `args`' own shape is
already confirmed (see "A concrete example" above): pull the
struct-name/field-name `String`s straight out of their `RCConst (Str
...)` positions, keep the struct-pointer/value `RCLocal`s, and discard
the erased `fs`/`ty` placeholders and the `FieldType` position integer
(confirmed elsewhere in this document to be redundant with the
field-name string, and not something any implementation should depend
on). Build `RStructGet`/`RStructSet` directly -- `postDrop` starts
empty here, the same way `ROp`'s own Phase 1 shape always constructs
`postDrop = []` and leaves filling it in to Phase 2 (see the `ROp`
constructor's own doc comment in `RCExp.idr`).

### Phase 2 (`annotate`): ownership, following `ROp`'s own pattern

```idris2
annotate natives owned (RStructGet fc structVar sn fn _) =
    pure $ wrapDups fc (splitBorrows natives owned [structVar])
                      (RStructGet fc structVar sn fn (boxedOperands natives [structVar]))
annotate natives owned (RStructSet fc structVar sn fn value _) =
    pure $ wrapDups fc (splitBorrows natives owned [structVar, value])
                      (RStructSet fc structVar sn fn value (boxedOperands natives [structVar, value]))
```

Direct reuse of `ROp`'s own already-existing `splitBorrows`/`wrapDups`/
`boxedOperands` helpers (`RC.idr:360-388`) -- no new ownership-analysis
logic, just applying the existing general-purpose one to a `List
RCLocal` built from the new nodes' own operands instead of `ROp`'s
`Vect arity RCLocal`. This is exactly what closes the gap the previous
section found in `RExtPrim`'s own handling: a struct pointer read by
two separate `getField` calls in the same function now gets a correct
`dup` before the first (non-last) use, the same as any other
multiply-read operand.

### Part A: struct-by-pointer FFI itself needs no new logic -- `CFStruct` can reuse `CFPtr`'s existing handling verbatim

Confirmed by comparing the two side by side: `cTypeOfCFType CFPtr =
"void *"` and `cTypeOfCFType (CFStruct x ys) = "void *"` already agree
(`Emit.idr:2241`/`2247`) -- a struct is always accessed by pointer in
this design (matches the "every struct name must appear in a
`%foreign` signature" contract already confirmed above, and matches
what Chez itself assumes -- see #36 in "What upstream's issue tracker
says" for what breaks when that assumption doesn't hold). So the two
genuinely broken cases --

```idris2
extractValue _ (CFStruct x xs) varName = idris_crash "..." -- Emit.idr:2295
packCFType (CFStruct x xs)     varName = "makeStruct(" ++ varName ++ ")" -- Emit.idr:2319, undefined function
```

-- can become direct copies of `CFPtr`'s own already-working lines:

```idris2
extractValue _ (CFStruct x xs) varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
packCFType (CFStruct x xs)     varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
```

This alone fixes `%foreign` functions that take or return a struct
pointer (`prim__makePoint`/`prim__pointFree` in the worked example
above) -- independent of `getField`/`setField`, and low-risk: reusing
an already-verified code path, not new logic.

### Part B: collection phase

At the top of `generateCSourceFile`, before `traverse_ (uncurry
createCFunctions) defs` runs, walk every `(Name, RCDef)` pair looking
for `MkRCForeign ccs fargs ret`, and recurse into `fargs`/`ret`'s own
`CFType`s the same way Chez's `mkStruct` does (`Compiler/Scheme/Chez.idr`,
cited above) -- through `CFIORes`/`CFFun` to find a `CFStruct n flds`
possibly nested inside. Collect every `(n, flds)` seen into a new
`Ref StructDefs (SortedMap String (List (String, CFType)))`, registered
alongside the existing `ConstDef`/`OutfileText`/etc. refs
`generateCSourceFile` already sets up. This is a direct structural port
of Chez's `Structs`/`mkStruct` -- same recursion shape, same "first
struct name seen wins, don't re-emit" dedup -- just building a
`SortedMap` instead of threading a `List String` `Ref`, and with no
Scheme code to emit.

### Part C: emitting the C struct definitions

In `header` (`Emit.idr`, called right after the `traverse_` in
`generateCSourceFile`, so field-type resolution during `createCFunctions`
doesn't depend on emission order), emit one `typedef struct { ... }
name;` per entry in the `StructDefs` table, translating each field's
`CFType` via the existing `cTypeOfCFType` -- no new type-to-C-type logic
needed, it's already there for `%foreign` arg/return types and a
struct field is the same kind of type.

### Part D: lowering `RStructGet`/`RStructSet` in `emitRC`

Add cases to `emitRC` (`Emit.idr:1882`, alongside the existing
`RExtPrim` case -- `prim__getField`/`prim__setField` no longer reach it
at all once Phase 1 converts them, so the existing `RExtPrim` case's
own whitelist/generic-call logic doesn't need touching):

```idris2
emitRC (RStructGet fc structVar sn fn postDrop) _ = do
    fields <- getStructFields sn   -- looks up the Ref from Part B
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar      -- reuses extractValue CFPtr's rendering (Part A)
    removeVars $ map varName postDrop   -- drops structVar per annotate's own decision
    pure $ packCFType ty ("((\{sn}*)\{ptr})->\{fn}")
emitRC (RStructSet fc structVar sn fn value postDrop) _ = do
    fields <- getStructFields sn
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar
    valC <- rcVarToC value          -- extractValue ty, since value's own Rep matches ty
    removeVars $ map varName postDrop
    pure $ "(((\{sn}*)\{ptr})->\{fn} = \{extractValue ty valC}, (IDRIS2RC2_Value*)NULL)"
```

(Sketch, not final syntax -- `getStructFields` denotes "look up
`StructDefs`, the `Ref` Part B populates"; exact plumbing for
`Ref`/error handling/how a C statement-vs-expression position gets
threaded follows whatever convention the surrounding `emitRC` cases
already use, not designed further here.) `packCFType`/`extractValue`
are the same existing functions Part A already fixed for `CFStruct`
itself -- reused again here for a *field's* `CFType`, not the struct
pointer's own. `postDrop` (now correctly populated by Phase 2, per
"Phase 2" above) tells this code exactly which operands to drop, the
same contract every other `postDrop`-carrying node already has --
Emit.idr doesn't re-derive ownership here, same as everywhere else in
this module (`Emit.idr`'s own module note).

### What can actually be ported from upstream, concretely

rc2 is a fully independent package that never edits `idris2-src`
(`README.md`'s own "What's here") and can't `import` code from it --
so "porting" here means re-deriving the same logic in rc2's own style,
not copying files. What that comes down to, concretely:

- **Direct algorithmic port** (same shape, rewritten in rc2's own
  idiom): the `Structs`-ref-and-`mkStruct` collect-once-per-struct-name
  pattern (Part B above) -- this is genuinely "the same idea, different
  language," including the `CFIORes`/`CFFun` recursion into a
  `%foreign` def's own return/argument types.
- **Not needed at all, already covered by existing rc2 code**:
  Chez's `cftySpec` (per-`CFType` Scheme-type-string generation) has
  no rc2 equivalent to write -- `cTypeOfCFType`/`extractValue`/
  `packCFType` already do the analogous job for every other `CFType`,
  `CFStruct` just needs to be added to the existing per-case functions
  the way Part A/C above do, not reimplemented from scratch.
- **Not portable, has to be written fresh**: `chezExtPrim`'s
  `GetField`/`SetField` cases emit Scheme (`ftype-ref`/`ftype-set!`)
  and rely on Chez Scheme's own macro-expansion-time type resolution;
  rc2 emits C directly and does its own resolution against the
  `StructDefs` table built in Part B. Same problem, structurally
  unrelated solution -- Part D (and the `RStructGet`/`RStructSet`
  nodes/Phase 1/Phase 2 machinery above) is original design, not a
  port. Chez also has no equivalent of this design's dedicated-node
  step at all -- Scheme's own dynamic typing means `chezExtPrim` can
  lower `GetField`/`SetField` directly from `ExtPrim`, with no
  ownership-tracking gap to work around the way rc2's `RExtPrim` has
  (see "Why a dedicated node" above) -- so that part of the design has
  no upstream analogue to port from at all.

## Open questions for rc2's own design

- ~~Unconfirmed: what happens, in any backend including Chez, when a
  program uses `getField`/`setField` on a struct name never mentioned
  in any `%foreign` signature~~ **Confirmed: Chez fails too, at compile
  time.** Ran this investigation's own repro above through `idris2 --cg
  chez` directly: `Exception: unrecognized ftype name my_struct ... /
  Error: INTERNAL ERROR: Chez exited with return code 255` -- Chez
  Scheme's own `ftype-ref` macro-expansion fails outright when no
  `(define-ftype my_struct ...)` was ever emitted for that name (i.e.
  no `%foreign` signature ever mentioned `Struct "my_struct" ...`).
  So requiring every struct name used with `getField`/`setField` to
  have appeared in at least one `%foreign` signature somewhere in the
  program is not a new restriction rc2 would be imposing -- it's the
  existing upstream contract, already enforced (just later than
  ideal -- at Scheme macro-expansion time rather than at Idris2
  compile time) by the reference backend. rc2 can rely on this and
  doesn't need to handle the "struct name never declared" case as
  anything other than a compile error of its own.
- **Not yet scoped: how field values interact with rc2's own
  Boxed/Native `Rep` split.** An `Int`-typed field read/written
  natively is plausible future work (the same shape
  `Compiler.RC2.ConAltNative` already caches for an ordinary
  constructor-destructured field, `rc2/doc/con-alt-native.md`) but
  should come after a basic, always-Boxed version works, not block it.
- **Not yet enumerated: every site that needs an `RStructGet`/
  `RStructSet` case added, now that they're real `RCExp` nodes.**
  "The new nodes" above names the general shape (`freeLocalsR`/
  `countUsesR`/`usedConstructorsR` in `RCExp.idr` at minimum, likely
  `Pretty.idr` for `--directive dumprcexpr` output too) but doesn't
  work through each site's actual required change -- that's
  implementation work. Every later pass (`Compiler.RC2.Reuse`,
  `Compiler.RC2.ConAltNative`, `Compiler.RC2.MutualLoop`,
  `Compiler.RC2.Loop`, `Compiler.RC2.Sink`, `Compiler.RC2.DualABI`)
  needs auditing for whether it needs a new case at all (most can
  likely just fall through a catch-all the way they already handle
  `RCon`/other leaf-ish nodes) or actively benefits from one (e.g.
  `Compiler.RC2.Sink`'s `sinkEligible` treating a struct field read as
  sinkable the same way it already treats `ROp`/`RCon`/`RAppName`) --
  not designed here, deliberately deferred to implementation time.

## Files

- Upstream issues: [#3830](https://github.com/idris-lang/Idris2/issues/3830)
  (the exact `extractValue` crash, still open, unfixed),
  [#2062](https://github.com/idris-lang/Idris2/issues/2062) (prior
  attempt at RefC `getField` support, abandoned -- see "What upstream
  Idris2's own issue tracker says" above for the key comment),
  [#1916](https://github.com/idris-lang/Idris2/issues/1916) (struct-
  by-value, out of scope), [#36](https://github.com/idris-lang/Idris2/issues/36)
  (Chez-specific nested-struct bug, out of scope for scalar fields),
  [#3809](https://github.com/idris-lang/Idris2/issues/3809) (recent,
  broader FFI proposal, out of scope for a first implementation).
- `idris2-src/libs/base/System/FFI.idr` -- `Struct`/`FieldType`/
  `getField`/`setField`/`prim__getField`/`prim__setField`.
- `idris2-src/src/Compiler/Scheme/Chez.idr` -- `chezExtPrim`'s
  `GetField`/`SetField` cases, `mkStruct`, `Structs`, `cftySpec`'s
  `CFStruct` case, `schFgnDef` (where `mkStruct` is invoked per
  `%foreign` def).
- `idris2-src/src/Compiler/RefC/RefC.idr` -- `cStatementsFromANF`'s
  `AExtPrim` dispatch (the `prims` whitelist RefC/rc2 share),
  `cTypeOfCFType`/`extractValue`/`packCFType`'s own `CFStruct` cases
  (the same gaps rc2 copied).
- `rc2/src/Compiler/RC2/Emit.idr` -- `emitRC`'s `RExtPrim` case (the
  `prims` whitelist), `cTypeOfCFType`/`extractValue`/`packCFType`'s own
  `CFStruct` cases (`extractValue`'s `idris_crash`, `packCFType`'s
  undefined `makeStruct` call), `generateCSourceFile`/`header` -- the
  proposed collection pass's own home, and the new `emitRC` cases for
  `RStructGet`/`RStructSet` (see "Design" above).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCForeign`, where a
  `%foreign` def's own `CFType` list currently ends up; `ROp`, the
  existing node `RStructGet`/`RStructSet` are shaped after (operand(s)
  + `postDrop`); `freeLocalsR`/`countUsesR`/`usedConstructorsR`, the
  structural-analysis functions a new node needs cases added to.
- `rc2/src/Compiler/RC2/RC.idr` -- `normalize`'s `LExtPrim`/`MkLForeign`
  cases (`RC.idr:163-164`/`244`, where the new
  `prim__getField`/`prim__setField` case slots in, and the direct
  `Lifted` -> `RCExp` `MkLForeign`/`MkRCForeign` copy this document's
  "How struct field types actually appear" section traces), `annotate`'s
  `ROp`/`RExtPrim` cases (`RC.idr:501-504`, the pattern
  `RStructGet`/`RStructSet`'s own `annotate` case follows/diverges
  from), `splitBorrows`/`splitBorrowsV`/`wrapDups`/
  `boxedOperands` (`RC.idr:360-388`, reused directly for the new
  nodes' own ownership computation).
- `idris2-src/src/Compiler/LambdaLift.idr` -- `LiftedDef`'s
  `MkLForeign`, `Lifted`'s `LExtPrim` -- where struct field types do
  (and don't) survive into the `Lifted` IR rc2's own `RC.idr` consumes.
- `rc2/src/Compiler/RC2/Inline.idr` -- `buildEligible`/
  `applyInlineLifted`, the whole-program collect-then-traverse shape a
  struct-field table would follow.
- `idris2-src/src/Idris/CommandLine.idr`, `idris2-src/src/Compiler/Common.idr`
  -- `--dumplifted`, the debug flag used to produce the example above.
- `idris2-src/src/TTImp/ProcessData.idr` -- `calcNaty`, the general
  "nat-like type" structural detection `FieldType` triggers (not a
  `Nat`-specific special case); `idris2-src/src/Core/CompileExpr.idr`
  -- `ConInfo`'s `ZERO`/`SUCC` tags this detection assigns.
