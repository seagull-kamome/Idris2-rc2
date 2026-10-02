# C struct FFI support (`System.FFI.Struct`/`getField`/`setField`): implemented, with a regression test

Upstream Idris2's `System.FFI` module (`idris2-src/libs/base/System/FFI.idr`)
provides direct access to C structs via `Struct`/`getField`/`setField`
(backed by the `prim__getField`/`prim__setField` ExtPrims), plus
struct-by-value `%foreign` arguments/returns (`CFStruct` in
`Core.CompileExpr`). The Chez backend fully supports both. RefC did
not -- and rc2, having copied RefC's own ExtPrim whitelist and
`extractValue`/`packCFType` verbatim, inherited the identical gap. This
document records what was confirmed, what upstream's own issue tracker
already says about this gap, the design ("Design: dedicated
`RStructGet`/`RStructSet` nodes, resolved in `normalize`" below,
verified against actual `RCExp`/generated-C output before any code was
written), and the implementation itself (on the `c-struct-support`
branch) -- see "Implementation status" below for what's actually done,
what was found and fixed along the way, and `rc2/tests/Test24CStructSupport.idr`
for the regression test (with `rc2/tests/verify.sh` itself extended to
support a per-test companion C file, needed to establish a struct name
via a real `%foreign` signature the way both rc2 and Chez require).

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
  the shape `Compiler.RC2.InlineCExp` already establishes: `buildEligible
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

## Design: dedicated `RStructGet`/`RStructSet` nodes, resolved in `normalize`

`getField`/`setField` do not stay `RExtPrim` calls. Phase 1 of
`Compiler.RC2.RC` (`normalize`, which lowers the named case trees to
`RCExp`) turns `prim__getField`/`prim__setField` into two dedicated
`RCExp` nodes, `RStructGet`/`RStructSet`, and resolves the struct and
field names there, against a table built from the program's `%foreign`
signatures. By the time `Emit` runs, a node already carries the struct's
field list and the field's `CFType`; `Emit` never looks a name up. The
lowering to C is a plain pointer dereference. The parts below follow the
data: the nodes, the two phases that build and annotate them, then the
emission side (Parts A to D).

### Why a dedicated node instead of lowering `RExtPrim` directly

Two facts decided it.

1. The struct-name and field-name arguments of a `getField`/`setField`
   call site are `RCConst (Str ...)` locals in the normalized code (see
   "A concrete example" above), so they can be pattern-matched at
   compile time and no runtime lookup is involved.
2. A struct accessor needs a different ownership rule from every other
   operand-consuming node. `ROp`'s (and `RExtPrim`'s) `annotate` case
   goes through `wrapDups fc (splitBorrows natives owned args) ...`: an
   operand that is still alive afterwards is `dup`'d, and the consumer
   later `drop`s its own reference. `getField`/`setField` lower to
   `((sn*)p)->f` and `((sn*)p)->f = v`; reading or writing through a
   pointer neither consumes nor needs a copy of the `IDRIS2RC2_Pointer`
   box, so a `dup` would be pure waste. When this design was made,
   `RExtPrim`'s `annotate` was a bare pass-through that never
   consulted `owned`; that gap has since been fixed separately (it leaked
   IORef cells and array prims' arguments, `tests/Test44IORefExtPrimLeak`),
   and `RExtPrim` now uses `splitBorrows`/`wrapDups`/`boxedOperands` like
   `ROp`. That does not make `ROp`'s shape right for a struct accessor,
   which is why the nodes have a rule of their own.

**What the rule is, and two designs that were rejected.** The first
attempt reused `ROp`'s `splitBorrows`/`wrapDups` pattern outright, but
there is no call left to model as consuming its operand. The second
dropped all ownership handling on the grounds that a pointer read
consumes nothing; that leaks a variable whose last use is the access
(`f s = getField s "x"`). Nothing else drops it: `branchBody` and
`dropDeadLet` (`RC.idr`) decide whether to drop a local by asking whether
it is still free in the rest of the body, and an `RStructGet` correctly
reports `structVar` as one of its free locals, so the access itself looks
like a use that keeps it alive. The accessor has to drop its operand
itself when this use is the operand's last one, and never `dup` it. That
is `dropIfLastUse` (`RC.idr`), described under "Phase 2" below.

### The new nodes

Defined in `RCExp.idr`:

```idris2
record StructField where
  constructor MkStructField
  structName : String
  fields : List (String, CFType)
  fieldName : String
  fieldType : CFType
  0 isField : Elem (fieldName, fieldType) fields

RStructGet : FC -> (structVar : RCLocal) -> StructField -> (postDrop : List RCLocal) -> RCExp
RStructSet : FC -> (structVar : RCLocal) -> StructField -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
```

A `StructField` is the struct's declared field list, the field's name and
`CFType`, and an erased proof that the field is in the list. `RStructSet`
evaluates to Unit. `postDrop` has the same role as `ROp`'s `postDrop`
field but a narrower meaning: it lists the operands (`structVar`, and for
`RStructSet` also `value`) for which this node is the last use, so they
are dropped after the read or write. It is `[]` after Phase 1. Neither
node ever inserts a `dup`. Every pass that walks `RCExp` has cases for
them (`freeLocalsR`/`countUsesR`/`mentionedLocalsAcc` in `RCExp.idr`,
`Loop.idr`'s `stripOwnership`, `Sink.idr`'s `genuinelyUsedR`,
`ConAltNative.idr`, `ConstFold.idr`, `DualABI.idr`, `LateInline.idr` and
so on); `structVar` and `value` always count as uses of those locals.
`DualABI` never treats the result of either node as a native value
(it is always the Boxed value `packCFType` renders).

### Phase 1 (`normalize`): `prim__getField`/`prim__setField` to the new nodes

`normalize` (`RC.idr`) matches `NmExtPrim` on `prim__getField` (in any namespace)
with the six arguments `[sn, _, _, sv, fn, _]` (the
erased field list and type, the struct pointer, the field name and the
`FieldType` position), and `prim__setField` with
`[sn, _, _, sv, fn, _, vl, _]` (the same plus the value and its erased
slot), ahead of the generic `NmExtPrim` case. It binds the arguments to
locals and requires `sn` and `fn` to be string literals. The
`FieldType` position is ignored: it is redundant with the field-name
string. The names are then resolved by `structField`:

- the program's struct table is the `StructTable` reference that
  `lowerProgram` (`RC2.idr`) fills before `normalizeProgram` runs, by
  folding `collectStructDefs` (Part B) over the `CFType`s of every
  `MkNmForeign` definition;
- a struct that appears in no `%foreign` signature, or a field it does
  not declare, is a compile-time `GenericMsg` error ("struct ... is used
  by getField/setField but appears in no %foreign signature" / "has no
  field ... in its %foreign declaration"). This is the same contract the
  Chez backend enforces, only earlier (see "Open questions" below);
- a call whose struct or field name is not a literal (for example a
  constructor argument that was not inlined) throws an `InternalError`
  prefixed with `notInlinedStructFieldMarker`. A normal compile reports
  it. An incremental compile (`--inc rc2`) catches exactly that prefix in
  `normalizeProgram`, drops the definition and its lifts, and so fails
  only at link time if the definition is actually used
  (`doc/incremental-compile.md`).

### Phase 2 (`annotate`): ownership

```idris2
annotate natives owned (RStructGet fc structVar sf _) =
    pure $ RStructGet fc structVar sf (dropIfLastUse natives owned [structVar])
annotate natives owned (RStructSet fc structVar sf value _) =
    pure $ RStructSet fc structVar sf value (dropIfLastUse natives owned [structVar, value])
```

`dropIfLastUse natives owned vars` returns the operands of `vars` that
this use is the last one of: still in `owned`, not a native local, and
not an immortal operand (`RCNull`/`RCConst`/`RCEmptyCon`/`RCConstCon`/
`RCConstClosure`). It walks `vars` left to right and removes each hit
from `owned`, so a local that occurs twice in one node (for example the
same local as `structVar` and `value`) is dropped once. It never
inserts a `dup`: an operand that is still alive afterwards needs no
action. `RForce` (`RC.idr`) uses the same function for its own operand.

### Part A: `CFStruct` is handled like `CFPtr`

A struct is always accessed by pointer: every struct name has to appear
in some `%foreign` signature (the contract Chez enforces too, see #36 in
"What upstream's issue tracker says"), and a `%foreign` function takes or
returns a pointer to it. So `Emit/Util.idr` gives `CFStruct` exactly
`CFPtr`'s rendering:

```idris2
cTypeOfCFType (CFStruct x ys) = "void *"
extractValue _ (CFStruct x xs) varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
packCFType (CFStruct x xs)     varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
```

Before this, `extractValue` crashed and `packCFType` called a
`makeStruct` that does not exist (both copied from RefC). The change
alone makes `%foreign` functions that take or return a struct pointer
work (`prim__makePoint`/`prim__pointFree` in the worked example),
independently of `getField`/`setField`. `cTypeOfCFType`, `extractValue`
and `packCFType` are top-level functions in `Emit/Util.idr` so that
`emitRC` can share them for a field's `CFType`.

### Part B: collecting the struct declarations

`collectStructDefs` (`Emit/Util.idr`) maps a `CFType` to the structs it
mentions, `SortedMap String (List (String, CFType))`. It recurses through
`CFIORes`/`CFFun` and into the field types of a struct (a field can be a
nested struct pointer). The first declaration of a name wins and later
ones are assumed identical, like Chez's `mkStruct`/`Structs`. It is run
over the `%foreign` definitions twice, once per consumer:

- `lowerProgram` (`RC2.idr`) builds the `StructTable` that `normalize`
  resolves `getField`/`setField` against (Phase 1);
- `generateCSourceFile` (`Emit.idr`) builds the `StructDefs` reference
  from the `MkRCForeign` definitions before any definition is lowered,
  so `header` sees every struct regardless of definition order.

A `%foreign`-declared struct type is the only way to bring a struct into
either table. `%export` signatures (`exportNfToCFType`, `RC2.idr`)
produce `CFStruct sname []` with an empty field list: only pointers cross
that boundary, and the table is not filled from them.

### Part C: emitting the C struct definitions

`header` (`Emit.idr`) writes one `typedef struct { <ctype> <field>; ... }
name;` for every entry of `StructDefs`, in a "struct definitions" block
ahead of all function definitions, with each field's C type taken from
`cTypeOfCFType` (a nested struct field is a `void *`). Names given as
`%cg rc2 externStruct=<name>` (`doc/directives.md`, section 5) are
filtered out of the emission only, because an included header already
`typedef`s them. `StructDefs` itself is not filtered, and field access to
such a struct resolves as usual.

### Part D: lowering `RStructGet`/`RStructSet` in `emitRC`

`emitRC` (`Emit.idr`) has one case per node, and no table lookup is
needed because the `StructField` is in the node. `prim__getField`/
`prim__setField` no longer reach the `RExtPrim` case, whose whitelist no
longer lists them.

- `RStructGet`: the struct pointer is read from its Boxed local
  (`rcVarToBoxedC`) and unwrapped with `extractValue CLangC CFPtr`. The
  expression `((sn*)ptr)->field` is cast to `cTypeOfCFType` of the
  field's type, because the real declaration (for an `externStruct`
  struct, a header's) may carry qualifiers such as `const char *`, and
  packed with `packCFType` (and a further `(IDRIS2RC2_Value*)` cast,
  since the packers of pointer-like types return a narrower pointer
  type). `CFInteger` is the exception: `mpz_t` has no cast syntax and
  `packCFType CFInteger` expects an out-parameter, so it is copied with
  `idris2rc2_mkIntegerFromMpz`. The `postDrop` operands are then
  dropped (`finalizeSinkWithDrop`).
- `RStructSet`: emits the statement `((sn*)ptr)->field = value;`, drops
  the `postDrop` operands, and evaluates to `(IDRIS2RC2_Value *)NULL`.
  A field of a type `cfTypeNative` maps reads `value` natively
  (`rcVarToNativeC`; `(char)`-cast for `CFChar`), so a constant is
  written as a literal. Rendering it Boxed and extracting it leaked a
  constant: inlining a setter into its only caller (`inlining.md`,
  Criterion B) passed `9.0` itself, which `rcVarToBoxedC` boxes and
  nothing frees (Test24 and Test120, 16 bytes under valgrind). Any other
  field type is read from the Boxed `value` through `extractValue`.

`postDrop` is computed by Phase 2, so `Emit` only discharges it and does
not derive ownership itself.

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
  rc2 emits C directly and resolves names itself, in `normalize`
  against the `StructTable` of Part B. Same problem, structurally
  unrelated solution -- Part D (and the `RStructGet`/`RStructSet`
  nodes/Phase 1/Phase 2 machinery above) is original design, not a
  port. Chez also has no equivalent of the dedicated-node step at all:
  Scheme's dynamic typing means `chezExtPrim` lowers `GetField`/
  `SetField` directly from `ExtPrim`, with no reference counts to
  track, so that part of the design has no upstream analogue.

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
- ~~Not yet scoped: how field values interact with rc2's own
  Boxed/Native `Rep` split~~ **Resolved: a struct field is never
  itself a Boxed (`IDRIS2RC2_Value*`) value, so there's no
  `ConAltNative`-style aliasing/dup question to answer at all.** A
  `CFStruct`'s own field list is `List (String, CFType)`
  (`Core/CompileExpr.idr:199`), and every `CFType` other than `CFUser`
  denotes a genuine C type with its own storage (`CFInt`/`CFDouble`/
  `CFPtr`/a nested `CFStruct`/etc.) -- exactly what `cTypeOfCFType`
  already renders for each case. `CFUser : Name -> List CFType ->
  CFType` (an arbitrary Idris2 type, rendered Boxed via `extractValue`'s
  own `(CFUser x xs) varName = "(IDRIS2RC2_Value*)" ++ varName` case)
  exists in the type *grammar*, but a genuinely Boxed, refcounted
  Idris2 value has no meaningful C struct-member storage -- there's no
  real C layout for "a slot holding a pointer this GC's own lifetime
  is tied to" the way there is for an `int`/`double`/plain pointer
  field. So `RStructGet`/`RStructSet`'s own field-type lookup can
  treat a `CFUser`-typed field as out of scope (nothing rejects it
  today: `collectStructDefs` (Part B) keeps it and `cTypeOfCFType`
  renders it as `void *`) rather than as a case needing real
  ownership design -- `getField`/`setField`'s read/write is always a
  `packCFType`/`extractValue` conversion against a genuine C-typed
  slot, never an aliased read of an already-Boxed value, so no `dup`
  is needed on the read side at all (unlike a constructor's own
  destructured field, which *is* a direct alias into Boxed storage --
  `Compiler.RC2.ConAltNative`'s own problem, not this one). Native
  (unboxed) reads/writes of a scalar field, bypassing the
  `packCFType`/`extractValue` round-trip for a value that's about to be
  used in a native context anyway, remains plausible future work (the
  same shape `Compiler.RC2.ConAltNative` already does for an ordinary
  constructor-destructured field, `rc2/doc/con-alt-native.md`) but is a
  performance optimization on top of a working, always-Boxed version,
  not a prerequisite for one.
- ~~Not yet enumerated: every site that needs an `RStructGet`/
  `RStructSet` case added~~ **Done -- see "Implementation status"
  below.** Every pass touching `RCExp` was audited; two real gaps were
  found and fixed (`Loop.idr`'s `stripOwnership`, `Sink.idr`'s
  `genuinelyUsedR`), the rest confirmed already-correct via their own
  wildcard fallthrough.

## Implementation status

Implemented on the `c-struct-support` branch (`RCExp.idr`, `RC.idr`,
`Loop.idr`, `Pretty.idr`, `Emit.idr`, `Sink.idr`, plus comment-only
updates to `DualABI.idr`/`ConAltNative.idr`/`Reuse.idr`), following the
design above essentially as written -- the one refinement made during
implementation, not anticipated by the design, is `dropIfLastUse`
itself: `RStructGet`/`RStructSet` never call `splitBorrows`/`wrapDups`
(no operand is ever duplicated), but a naive "drop nothing" reading of
the design leaked a struct pointer used exactly once and never again
(`f s = getField s "x"`) -- traced `annotateDef`/`branchBody`/
`dropUnusedOwnedVars` by hand against that exact repro before landing
on the `owned`-consulting-but-never-`dup`-inserting shape described
above.

**Verified by hand**, since no dedicated `verify.sh`-integrated
regression test exists yet (see below): a program declaring a struct
via a `%foreign` signature, then reading/writing several fields
(including rereading a field twice, and reusing a `setField` value
operand three more times afterward -- exercising `dropIfLastUse`'s
occurrence-order handling on both `RStructGet` and `RStructSet`) --

- compiles cleanly and produces the expected output,
- generates the C shown in "A concrete example" style below:
  ```c
  typedef struct { int64_t x; double y; } point;
  /* ... */
  IDRIS2RC2_Value *primVar_9 = idris2rc2_mkInt64(((point*)((IDRIS2RC2_Pointer*)var_0)->p)->x);
  idris2rc2_drop(var_0);
  return primVar_9;
  ```
  (`RStructGet`, direct pointer dereference, `postDrop` discharged as
  a plain `idris2rc2_drop`, no branch/dup anywhere), and
  ```c
  ((point*)((IDRIS2RC2_Pointer*)var_0)->p)->y = (idris2rc2_to_double(var_1));
  idris2rc2_drop(var_0);
  idris2rc2_drop(var_1);
  ```
  (`RStructSet`, same shape, both operands dropped only because that
  particular call site happened to be each one's own last use),
- is `valgrind --leak-check=full` clean (`definitely lost: 0 bytes`,
  `0 errors`) in every variant tried.

**A follow-up audit** (prompted by direct review, after the field-
reuse case above had already been caught by review and fixed) checked
every other pass touching `RCExp` for whether its own wildcard
fallthrough correctly covers the two new nodes. Two real gaps found
and fixed:
- `Loop.idr`'s `stripOwnership` filters `ids` out of `ROp`/`RCmpCase`/
  `RLoopContinue`/`RLoop`'s own `postDrop`/`prologueDrop` fields (used
  by `Compiler.RC2.ConAltNative`/`Compiler.RC2.DualABI` when promoting
  a local to a native shadow) but fell through its own wildcard for
  `RStructGet`/`RStructSet`, which have the identical kind of
  `postDrop` field -- a native-promoted local surviving there would
  have emitted a drop for a value never boxed in the first place.
- `Sink.idr`'s `genuinelyUsedR` (a free-variable analysis almost
  identical to `RCExp.idr`'s own `freeLocalsR`) didn't count
  `structVar`/`value` as a genuine use, the same class of bug that
  caused branch-sinking's own real, previously-fixed miscompile
  (`TestBuffer.idr`, see `rc2/doc/branch-sinking.md`'s "Not peeling
  through var's own death") -- left uncaught, `trySinkInto`'s `RLet`
  case could sink a binding past a `getField`/`setField` call that was
  actually reading it, producing a use-before-definition reference in
  the generated C.

Every other site audited (`Reuse.idr`'s `tryClaim`/`tryConsume`/
`resolveReuse`, `ConAltNative.idr`'s `peelWrappers`/
`applyConAltNativeExp`, `MutualLoop.idr`'s `tailCallTargets`/
`buildGroup` -- which delegates renaming entirely to `Loop.idr`'s own
`renameRCExp`, already fixed alongside the initial implementation --
and `DualABI.idr`'s `tailValueReps`/`applyCallSiteRewriteBody`)
confirmed its own wildcard fallthrough is already correct for both new
nodes -- comments naming the specific node list were updated to say so
explicitly where they existed, no behavior changes needed. Full
`refc-suite` (19/19) and smoke-test (23/23) regression suite passes
throughout, with no changes -- confirming neither the new nodes nor
the `Emit.idr` `where`-clause refactor (Part A's `cTypeOfCFType`/
`extractValue`/`packCFType` lifted to top level) regressed anything.

**Now has a proper `rc2/tests/verify.sh`-integrated regression test**:
`rc2/tests/Test24CStructSupport.idr`, with a real companion C
constructor/destructor pair (`Test24CStructSupport.c`/`.h`) exercising
`RStructGet`/`RStructSet`'s own `dropIfLastUse` ownership handling
directly -- a field reread twice in a row (`structVar` used twice, no
`dup` either time) and a `setField` call's own `value` operand reused
three more times afterward. `verify.sh` itself gained the general
mechanism this needed: a `TestN.c` alongside `TestN.idr` is compiled
once and linked in via `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` automatically
-- a no-op for every other existing test, but reusable by any future
smoke test whose own `%foreign` declarations need a real C
implementation, not just an rc2/RefC-provided primitive. Joins
`NO_REFC_DIFF_TESTS` (real RefC has no `getField`/`setField` to diff
against) with a hand-verified `.expected`, and `LEAK_SENSITIVE_TESTS`
(ownership correctness is the whole point of this test). Full
`verify.sh` run: 39 passed, 1 known pre-existing (`Test111Basics/Basics.idr`'s own
recorded leak, unrelated), 0 failed -- including this test's own
`valgrind` pass at 0 bytes definitely lost.

One thing the C-level typedef collision while writing the companion
file surfaced, worth recording: rc2's own generated C already emits
`typedef struct { ... } name;` for every struct in `StructDefs` (Part
C above), so a companion header declaring the *same* struct shape
again (even byte-for-byte identical) trips a duplicate-typedef error
once both are `#include`d into the same translation unit --
`Test24CStructSupport.h` sidesteps this by declaring its own two
functions `void*`-typed rather than `test_point*`-typed, with the real
`test_point` typedef kept local to the `.c` file. Not an rc2 bug (any
companion C file establishing a struct name this way will hit the same
thing), but worth knowing before writing another test like this one.

**Now has a real fix**: `%cg rc2 externStruct=<name>` (`rc2/doc/directives.md`
section 5) suppresses `header`'s own `typedef struct` for one or more
named structs, for exactly this case -- a struct name already
`typedef`'d by an included system/library header (a real example:
libcurl's own `curl/curl.h` already typedefs `curl_version_info_data`,
`idris2-curl`'s own `doc/version-info-struct.md`). `StructDefs` (this
section's own Part B/C table) is never filtered by it, only the
typedef *emission* in Part C -- `RStructGet`/`RStructSet` (Part D)
resolve fields exactly as normal either way. See
`rc2/tests/Test120CStruct/` for a from-scratch example built the
"right" way (a companion header declaring the real typedef, not a
`void*`-typed workaround like `Test24CStructSupport.h` above).
`Test24CStructSupport` itself is left as originally written -- its own
`void*` sidestep still works fine and isn't wrong, just no longer the
only option.

## Investigated: native (unboxed) `Ptr`/`CFPtr` representation -- not pursued

Prompted by a direct question after the implementation landed: neither
`getField`'s own result nor `setField`'s own `value` operand is ever
promoted to `Rep`'s `RNative` (`Compiler.RC2.Types`'s own `repOf` only
proposes it for `ROp`/`RPrimVal`, `RStructGet` has no case and falls
through to `Nothing`) -- and, more specifically, `structVar` itself
(the struct pointer, `CFPtr`-shaped since Part A) is always Boxed too,
paying for one `IDRIS2RC2_Pointer` heap allocation (`packCFType CFPtr
= idris2rc2_mkPointer(...)`) just to carry one raw pointer around.
Investigated whether `Ptr`/`CFPtr` values generally (not just struct
pointers) could go through rc2's existing native-representation
machinery the way fixed-width scalars already do.

**Structurally blocked before the semantics even come up**: `Rep`'s
own `RNative`/`RInlineNative` are typed as `RNative PrimType`, and
`PrimType` (`idris2-src/src/Core/TT/Primitive.idr`) -- upstream's own
type, not rc2's -- has no pointer case at all (`IntType`/.../
`DoubleType`/`CharType`/`WorldType`, nothing else).
`Compiler.RC2.Types`'s own `nativeEligible` only accepts a subset of
those. Representing a native pointer at all would need a new `Rep`
variant of rc2's own, since there's no existing `PrimType` value to
reuse -- a change touching every module that pattern-matches on `Rep`
(`RC.idr`, `Types.idr`, `Emit.idr`, `Loop.idr`, `DualABI.idr`).
Compounding that: `RCExp` has already erased Idris2's own type
information by the time any of this runs, so recognizing "this
particular Boxed local is actually a pointer" would only be possible
at the handful of sites that still carry `CFType` information
first-hand (`RStructGet`'s own field type, a `%foreign` call's own
return type) -- not a general local-type inference the way
`ROp`/`RPrimVal`-driven native promotion is today.

**Even setting that aside, the semantics don't hold up as cleanly as a
scalar's do.** A native pointer would need to mean "copied by value,
no refcounting" -- true for a plain address -- but two real problems
surface:

- **`CFGCPtr` would break outright.** `idris2rc2_mkGCPointer(raw,
  onCollect)` runs `onCollect` when the *Boxed wrapper* is collected --
  a real dependency on refcounting to trigger external cleanup. Any
  native-pointer design would have to exclude `CFGCPtr` explicitly and
  keep it Boxed-only forever; only `CFPtr` (no collection callback)
  could ever be a candidate.
- **`CFPtr` itself loses a safety net, not just an allocation.** The
  current `IDRIS2RC2_Pointer` wrapper doesn't protect the memory a raw
  pointer points at (that's already entirely the programmer's own
  responsibility -- see `Test24CStructSupport.idr`'s own explicit
  `prim__freePoint` call), but it does mean *something* in the IR
  tracks whether a given copy of that pointer is still reachable
  (ordinary `dup`/`drop`). A native pointer is copied freely with zero
  tracking of any kind -- not a regression in what rc2 already
  guarantees about the pointed-to memory (nothing), but a real
  reduction in what's visible/checkable in the IR itself. Struct
  fields that are themselves pointers (a future nested-struct feature)
  would compound this further -- reasoning about a field pointer's own
  lifetime relative to its owning struct's lifetime is exactly the
  kind of thing a real borrow/lifetime checker exists for, and rc2 has
  none.

**Conclusion**: semantically plausible for `CFPtr` specifically (a
pointer value genuinely is "copy, no refcount" the same way a scalar
is), but not pursued -- the `Rep`-widening cost is broad, `CFGCPtr`
would need permanent exclusion, and the loss of even the weak
reachability tracking `IDRIS2RC2_Pointer` currently provides is a real
open question rather than a solved one. Revisit only if profiling
shows the `IDRIS2RC2_Pointer` allocation cost actually matters in
practice, with a concrete plan for the `CFGCPtr` split and the
lifetime question above -- not currently planned.

## Files

- `rc2/tests/Test24CStructSupport.idr`/`.c`/`.h`/`.expected` -- the
  regression test; `rc2/tests/verify.sh` -- the companion-C-file
  compile-and-link mechanism this test needed (`if [ -f
  "$RC2_DIR/tests/$name.c" ]; then ...`), plus its own
  `NO_REFC_DIFF_TESTS`/`LEAK_SENSITIVE_TESTS` entries for this test.
- `rc2/src/Compiler/RC2/RCExp.idr` -- `Rep`'s own `RNative`/
  `RInlineNative PrimType`, the "Investigated: native `Ptr`/`CFPtr`"
  section's own starting point. `rc2/src/Compiler/RC2/Types.idr` --
  `nativeEligible`/`repOf`. `rc2/src/Compiler/RC2/Emit.idr` --
  `packCFType`/`extractValue`'s own `CFPtr`/`CFGCPtr` cases
  (`idris2rc2_mkPointer`/`idris2rc2_mkGCPointer`).
- `idris2-src/src/Core/TT/Primitive.idr` -- upstream's own `PrimType`,
  confirming it has no pointer case for `Rep`'s `RNative` to reuse.
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
  `prims` whitelist, which no longer lists `prim__getField`/
  `prim__setField`), the `RStructGet`/`RStructSet` cases, and
  `generateCSourceFile`/`header` (the `StructDefs` collection and the
  `typedef struct` emission, Parts B and C of "Design" above).
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `cTypeOfCFType`/`extractValue`/
  `packCFType`'s own `CFStruct` cases (Part A: `CFPtr`'s rendering; they
  used to be an `idris_crash` and a call to an undefined `makeStruct`),
  and `collectStructDefs` (Part B).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `StructField`, the `RStructGet`/
  `RStructSet` nodes (their `postDrop` has `ROp`'s role without its
  `splitBorrows`/`wrapDups` dup-insertion half), `MkRCForeign`, where a
  `%foreign` def's own `CFType` list ends up, and the structural-analysis
  functions (`freeLocalsR`/`countUsesR`/`mentionedLocalsAcc`) that have
  cases for the nodes.
- `rc2/src/Compiler/RC2/RC.idr` -- `normalize`'s `prim__getField`/
  `prim__setField` cases and `structField` (Phase 1), `annotate`'s
  `RStructGet`/`RStructSet` cases and `dropIfLastUse` (Phase 2; `ROp`'s
  `splitBorrows`/`wrapDups` inserts `dup`s, `dropIfLastUse` never
  does), `branchBody`/`dropDeadLet` (the "drop what is not used any
  more" machinery that "Design" above explains cannot cover
  `structVar`/`value` on its own), and `normalizeProgram`'s catch of
  `notInlinedStructFieldMarker` for incremental compiles.
- `rc2/src/Compiler/RC2/RC2.idr` -- `lowerProgram`, which builds the
  `StructTable` from the `%foreign` definitions before Phase 1.
- `idris2-src/src/Compiler/LambdaLift.idr` -- `LiftedDef`'s
  `MkLForeign`, `Lifted`'s `LExtPrim` -- where struct field types do
  (and don't) survive into the `Lifted` IR rc2's own `RC.idr` consumes.
- `idris2-src/src/Idris/CommandLine.idr`, `idris2-src/src/Compiler/Common.idr`
  -- `--dumplifted`, the debug flag used to produce the example above.
- `idris2-src/src/TTImp/ProcessData.idr` -- `calcNaty`, the general
  "nat-like type" structural detection `FieldType` triggers (not a
  `Nat`-specific special case); `idris2-src/src/Core/CompileExpr.idr`
  -- `ConInfo`'s `ZERO`/`SUCC` tags this detection assigns.
