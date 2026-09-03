# `%export` support (`Compiler.RC2.RC2.validateExport`, `Compiler.RC2.Emit.emitExportWrapper`)

Idris2's `%export "lang:exportedCName"` pragma (same attachment syntax
as `%foreign`, but for the opposite direction -- making an Idris
function callable from outside, rather than binding an external one)
did nothing in rc2 before this: `compileExpr` passed `exports=[]` to
`getCompileData`, so `CompileData.exported` was always empty and the
pragma was silently ignored. No upstream backend does real C-ABI
marshalling for it either -- RefC ignores it entirely, and the JS
backend only unmangles the name (still a JS closure underneath, not a
native call boundary). This makes rc2 the first backend to generate a
genuine native-C-ABI entry point for an `%export`ed function.

## Design: an additive wrapper, not a conversion

An `%export`ed function's own always-Boxed compiled entry point
(`Main_add`, etc.) is **never touched**. `Compiler.RC2.Emit`'s
`emitExportWrapper` generates one extra C function, under the
user-given name, with native C parameter/return types: it boxes each
native argument, calls the original entry point, trampolines the
result, and unboxes it back to a native C value. This mirrors how
`%foreign`'s own FFI worker synthesis (`Compiler.RC2.DualABI`'s Stage
3c) already treats the boxed/native boundary, except in the opposite
direction (native-in calling boxed, rather than boxed-in calling
native).

Recognized `%export` tags: `"RC2:..."`, `"RefC:..."`, `"C:..."` (the
same `getCompileDataWith` filter list `%foreign`'s own multi-backend
tag convention uses) -- so an existing `%export "RefC:..."` or
`%export "C:..."` declaration written for another backend, or written
generically, also works unmodified through rc2.

## Worked example: compiling and calling an exported function

Assumes the self-built toolchain from this repo's own top-level
`README.md` ("Building and running") is already set up, and
`rc2/build/exec/idris2-rc2` already exists (see also the
`run-idris2-rc-cg` skill). Two files, in a scratch directory:

`Add.idr`:

```idris
module Main

%export "C:add_two_ints"
add : Int -> Int -> Int
add x y = x + y

%foreign "C:call_add_from_c,libc,Add.h"
prim__callAddFromC : PrimIO Int

main : IO ()
main = do
  printLn (add 2 3)          -- ordinary Idris call, wrapper untouched
  r <- primIO prim__callAddFromC
  printLn r                  -- proves the export is callable from plain C
```

`Add.c` (+ a matching `Add.h` declaring both `add_two_ints` -- the
rc2-generated wrapper, `extern`, no rc2 API involved -- and
`call_add_from_c` for `%foreign` above to bind):

```c
#include "Add.h"

int64_t call_add_from_c(void) {
    return add_two_ints(10, 32);
}
```

Build: compile the companion `.c` to an object file first, then point
`idris2-rc2` at it via `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` (the same
upstream-Idris2 env vars `Compiler.RC2.CC`'s own
`findCFlags`/`findLDFlags` read -- this is exactly what
`rc2/tests/verify.sh` does for every smoke test with a companion `.c`
file, see its own comment above `IDRIS2_LDFLAGS=...`):

```sh
source env.sh   # from the repo root; puts install/bin/idris2-rc2's
                # runtime bits + the self-built toolchain on PATH

nix-shell -p gcc --run 'gcc -c Add.c -o Add.o'

IDRIS2_LDFLAGS="$PWD/Add.o" IDRIS2_CFLAGS="-I$PWD" \
  nix-shell -p gcc gmp pkg-config --run \
  '/path/to/idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 Add.idr -o add_demo'

./build/exec/add_demo
```

Expected output:

```
5
42
```

(`5` = `add 2 3` called ordinarily from Idris; `42` = `10 + 32`
computed by calling the same `add_two_ints` wrapper from `Add.c`, with
no Idris/rc2 API involved on the C side at all.) Note `idris2-rc2`
places the linked executable under `./build/exec/<name>`, same as
upstream `idris2` -- not at the `-o` name directly in the current
directory.

### Variant: external C owns `main` (`--directive nomain`)

Drop the `%foreign` round-trip and give the companion `.c` file its own
`main()` instead -- the shape a real `%export` consumer usually wants.
This needs `--directive nomain` (see "Linking as a library" below) so
rc2's own generated `main()` doesn't collide with it at link time.

`AddLib.idr` (same `%export` as `Add.idr` above; its own Idris `main`
is never reached):

```idris
module Main

%export "C:add_two_ints"
add : Int -> Int -> Int
add x y = x + y

main : IO ()
main = putStrLn "this Idris main should never run"
```

`driver.c` (owns the real `main`, calls the export directly):

```c
#include <stdint.h>
#include <stdio.h>

extern int64_t add_two_ints(int64_t, int64_t);

int main(void) {
    printf("%lld\n", (long long)add_two_ints(10, 32));
    return 0;
}
```

```sh
nix-shell -p gcc --run 'gcc -c driver.c -o driver.o'

IDRIS2_LDFLAGS="$PWD/driver.o" \
  nix-shell -p gcc gmp pkg-config --run \
  '/path/to/idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 --directive nomain AddLib.idr -o addlib_demo'

./build/exec/addlib_demo   # prints 42 -- driver.c's own main ran, not Idris's
```

## Scope: scalar types only

`Compiler.RC2.RC2.exportNfToCFType` recognizes exactly: `Int`,
`Int8`/`Int16`/`Int32`/`Int64`, `Bits8`/`Bits16`/`Bits32`/`Bits64`,
`Double`, `Char`, and `IO`/`PrimIO.IORes` wrapping any of those (or
`IO ()`). Nothing else -- no `String`, `Ptr`, `Buffer`, `Integer`,
struct, user-defined ADT, or closure argument/return, deliberately
narrower than `%foreign`'s own vocabulary
(`Compiler.CompileExpr.nfToCFType`/`getCFTypes` upstream, not reused
here since those accept the full FFI type list). A declaration outside
this scope fails immediately and attributably, at compile time, with
the offending argument position(s) or return type named in the error --
not a downstream linker mystery. Manually verified (no automated
negative-test harness exists in `verify.sh` for "expect this specific
compile error", and this doesn't introduce one): exporting a
`String -> String` function produces

```
Error: [rc2] %export declaration <name> (Main.bad)'s own argument(s) [0]
own type isn't a supported native scalar -- %export only supports
scalar-typed (Int/Int8/.../Double/Char) arguments
```

## The `IO`/`PrimIO` return-type special case, and the World argument

`IO`/`IORes` are both genuine `data` types (`libs/prelude/PrimIO.idr`),
so a `T1 -> T2 -> IO R`-typed export's own normalized type is an
ordinary `NTCon` wrapping `R`, peeled via `Compiler.RC2.DualABI.peelIORes`
the same way `%foreign` already peels a `PrimIO`/`CFIORes` return.
`CFUnit` (an `IO ()`-returning export) is accepted as a special case
with no native marshalling on the return side at all -- the wrapper's
own C return type is `void`, and the trampolined result is discarded
unread, mirroring how `Compiler.RC2.Emit`'s own generated `main()`
discards the top-level program's final result the same way.

Empirically confirmed while implementing this (not assumed from source
reading alone): unlike `main`'s own well-known entry point
(`__mainExpression`, arity 0 -- its `%World` token is already applied
once, at the very top of the whole program, before lambda lifting), an
*ordinary* `IO`/`IORes`-returning function still carries a real,
un-erased trailing `%World` parameter (quantity 1, not 0) all the way
through to its compiled (`Lifted`) arity. A naive scalar-argument-count
comparison against the compiled definition's own arity throws a
spurious mismatch on every IO-returning export otherwise;
`Compiler.RC2.RC2.validateExport` accounts for this one extra slot when
an export's return type is `CFIORes _`, and `emitExportWrapper` supplies
it as a boxed `NULL` constant when calling in -- the same placeholder
`Compiler.RC2.EmitUtil`'s own `packCFType`/`extractValue` already use
for `CFWorld` everywhere else.

## Memory: an explicit drop after every non-`Unit` return

Every ordinary Rep-driven code path in rc2's own compiled output has
its ownership/drop bookkeeping decided once, statically, by
`Compiler.RC2.RC`'s `annotate` pass and baked into the tree as explicit
`RDrop`/`RFree` nodes. `emitExportWrapper` is hand-written raw C text,
outside that pipeline entirely, so it's responsible for its own
correctness here: after `extractValue` reads the trampolined boxed
result's native payload out, the wrapper explicitly
`idris2rc2_drop`s it. This is a real fix, not defensive paranoia --
unlike `main`'s own footer (which can get away with never dropping its
final result, since the process exits immediately after), this wrapper
can be called an arbitrary number of times from external C, and a
heap-allocating return (`CFInt`/`CFInt64`/`CFUnsigned64`/`CFDouble`)
would otherwise leak on every single call. The drop is unconditional
(including for `CFChar`/`CFInt8`/.../`CFUnsigned32`, whose values are
never real heap allocations) because `idris2rc2_drop` already no-ops
safely on an always-unboxed or `NULL` value -- see
`Compiler.RC2.Types.alwaysUnboxed`'s own doc comment for why that
no-op is itself a documented runtime guarantee, not an implementation
accident.

## Two scope items not implemented (v1)

- **No generated C header.** The wrapper's own prototype has to be
  hand-declared `extern` by whatever C code calls it (see
  `rc2/tests/Test59ExportScalar.h` for the pattern) -- rc2 doesn't
  emit a `.h` of its own alongside the generated `.c` yet.
- **Scalar types only**, per "Scope" above -- no struct-by-value, no
  user-defined ADT, no `String`/`Ptr`/`Buffer`/`Integer` marshalling on
  an `%export` boundary (all of which `%foreign` already supports in
  the opposite direction).

## Linking as a library (`--directive nomain`)

Every generated `.c` used to unconditionally end with its own C
`main()` (`Compiler.RC2.Emit`'s `footer`) that calls
`__mainExpression_0()` and trampolines the result. That's fine for an
ordinary standalone executable, but it meant a companion `.c` file that
defines its own `main()` -- exactly the shape an `%export` consumer
naturally wants, a hand-written C driver that owns `main` and calls
straight into the exported symbol -- would produce a duplicate-symbol
link error. `--directive nomain` / `%cg rc2 nomain` fixes this:
`footer` is skipped entirely, so the generated `.c` has no `main()` of
its own and links cleanly alongside an external one. See "Worked
example" above ("Variant: external C owns `main`") for a complete,
verified-working walkthrough.

## DeadCode survival

An `%export`ed name is a root `Compiler.RC2.DeadCode.pruneDeadDefs`
must never drop, regardless of whether anything else in the program
calls it -- `Compiler.RC2.RC2.compileExpr`'s own `roots` list already
included `exported cdata`'s names for exactly this reason, before this
feature ever populated that list with anything (it was always `[]` in
practice). One real bug was found and fixed while wiring this up for
real: `Compiler.Common.getExports` resolves each exported name via
`resolved`, not `toFullNames`, so `exported cdata`'s own `Name`s are in
`Resolved` (context-index) form, while every entry in the `RCDef`
pipeline `pruneDeadDefs` walks is keyed by full name -- a structural
`Name` equality check, which a `Resolved`-form root would never
actually match. `roots` now reuses `validateExport`'s own
`getFullName`-resolved name instead of re-deriving (and getting wrong)
its own copy. Confirmed with a third export
(`Test59ExportScalar.idr`'s `unused`) that `main` never calls: both its
own wrapper and its own original always-Boxed entry point
(`idris2rc2_test_unused`/`Main_unused`) still appear in the generated
C.

## Reference test

`rc2/tests/Test59ExportScalar.idr` + its `.c`/`.h` companion: two
`%export`ed scalar functions (`Int`/`Double`) called both from ordinary
Idris code and from plain hand-written C (via a `%foreign`-bound C
function that calls the exported symbols directly, with no Idris/rc2
API involved), plus a third, otherwise-unused export proving the
DeadCode-survival guarantee above. Listed in `verify.sh`'s
`NO_REFC_DIFF_TESTS` -- real RefC has no `%export` marshalling at all,
so a `--cg refc` comparison build would just fail to link the
companion `.c` file's `extern` declarations, not validate anything.
