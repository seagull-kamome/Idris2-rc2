# C struct FFI support (`System.FFI.Struct`/`getField`/`setField`): investigating

Upstream Idris2's `System.FFI` module (`idris2-src/libs/base/System/FFI.idr`)
provides direct access to C structs via `Struct`/`getField`/`setField`
(backed by the `prim__getField`/`prim__setField` ExtPrims), plus
struct-by-value `%foreign` arguments/returns (`CFStruct` in
`Core.CompileExpr`). The Chez backend fully supports both. RefC does
not -- and rc2, having copied RefC's own ExtPrim whitelist and
`extractValue`/`packCFType` verbatim, inherited the identical gap. This
document records what's been confirmed so far and the open design
questions, before any implementation work starts.

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

## Open questions for rc2's own design

- **A `Structs`-ref-and-`mkStruct`-style mechanism looks like the
  natural port**, and is now concretely scoped (see "How struct field
  types actually appear in `Lifted`" above): a first pass collecting
  every `CFStruct n flds` out of every `MkRCForeign` in the whole
  compiled program into a `SortedMap String (List (String, CFType))`
  (or similar), built the same way `Compiler.RC2.Inline`'s
  `buildEligible` already is, then a second pass resolving each
  `getField`/`setField` call site's struct-name/field-name string
  literals against it. rc2 gets to emit a real C `typedef struct {
  ... } name;` once per struct and lower straight to `((name*)ptr)->
  field` reads/writes -- leaning on the C compiler for layout math
  instead of hand-rolling a Scheme `ftype` the way Chez does. Not
  designed in full yet -- the two-pass shape and where the table lives
  are known; the exact `RC2.idr` `toRCDefs` wiring (where the
  collection pass slots into the existing pipeline order) still needs
  to be worked out.
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

## Files

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
  undefined `makeStruct` call).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCForeign`, where a
  `%foreign` def's own `CFType` list currently ends up.
- `idris2-src/src/Compiler/LambdaLift.idr` -- `LiftedDef`'s
  `MkLForeign`, `Lifted`'s `LExtPrim` -- where struct field types do
  (and don't) survive into the `Lifted` IR rc2's own `RC.idr` consumes.
- `rc2/src/Compiler/RC2/RC.idr` -- `normalizeDef`'s `MkLForeign`/
  `LExtPrim` cases, the direct `Lifted` -> `RCExp` copy this document's
  "How struct field types actually appear" section traces.
- `rc2/src/Compiler/RC2/Inline.idr` -- `buildEligible`/
  `applyInlineLifted`, the whole-program collect-then-traverse shape a
  struct-field table would follow.
- `idris2-src/src/Idris/CommandLine.idr`, `idris2-src/src/Compiler/Common.idr`
  -- `--dumplifted`, the debug flag used to produce the example above.
- `idris2-src/src/TTImp/ProcessData.idr` -- `calcNaty`, the general
  "nat-like type" structural detection `FieldType` triggers (not a
  `Nat`-specific special case); `idris2-src/src/Core/CompileExpr.idr`
  -- `ConInfo`'s `ZERO`/`SUCC` tags this detection assigns.
