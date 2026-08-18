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

## Open questions for rc2's own design

- **A `Structs`-ref-and-`mkStruct`-style mechanism looks like the
  natural port.** Collect every `CFStruct`'s field list the first time
  a `%foreign` signature mentions it, emit a real C `typedef struct {
  ... } name;` once (rc2 gets to lean on the C compiler for layout math
  instead of reinventing it, unlike Chez which has to hand-roll
  `ftype`s). `getField`/`setField` call sites sharing that struct name
  would then resolve to plain `((name*)ptr)->field` reads/writes,
  looked up in the same table by the (string-literal) struct/field
  names. Not designed yet -- needs a concrete plan for where this
  collection pass reads `%foreign` defs from and where the resulting
  table lives across rc2's own pipeline stages.
- **Unconfirmed: what happens, in any backend including Chez, when a
  program uses `getField`/`setField` on a struct name never mentioned
  in any `%foreign` signature** -- e.g. built via `believe_me` from a
  raw pointer, exactly this investigation's own repro above. If Chez's
  own `(ftype-ref undeclared-name ...)` also fails in that case (needs
  checking directly, not assumed), rc2 wouldn't need to solve a
  strictly harder problem than upstream already leaves unsolved --
  worth confirming before treating it as a requirement.
- **Where `%foreign` signatures are visible in rc2's own pipeline.**
  Unlike ordinary `RExtPrim` call sites (which flow all the way through
  to `Compiler.RC2.Emit`), a `%foreign` def's own argument/return
  `CFType`s are consumed close to `MkRCForeign` (`RCExp.idr`). Needs
  tracing where that data currently lives/is discarded in rc2's own
  `toRCDefs` pipeline before a `Structs`-style collection pass can be
  designed -- not investigated yet.
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
