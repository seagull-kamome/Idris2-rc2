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

## Scope: scalars, pointers, structs, Integer, and String

`Compiler.RC2.RC2.exportNfToCFType` recognizes: the original scalar set
(`Int`, `Int8`/`Int16`/`Int32`/`Int64`, `Bits8`/`Bits16`/`Bits32`/
`Bits64`, `Double`, `Char`), plus `Ptr`/`AnyPtr`, `GCPtr`/`GCAnyPtr`,
`Integer`, `String`, and any `Struct "name" [...]` (matched by bare
type-constructor name, ignoring namespace -- the same `getNArgs`
precedent upstream's own `Compiler.CompileExpr` uses), and
`IO`/`PrimIO.IORes` wrapping any of those (or `IO ()`).
`Compiler.RC2.RC2.isExportableCFType` is the actual per-position gate
`validateExport` checks: it admits `CFPtr`/`CFGCPtr`/`CFInteger`/
`CFString`/`CFStruct` explicitly (each has a real marshalling path in
`EmitUtil`'s `packCFType`/`extractValue`, unrelated to the narrower,
purely-scalar `cfTypeNative` predicate several other codegen stages
share for Rep selection) on top of the same scalar set as before.

Still nothing for `Buffer`, any other user-defined ADT (`List`,
`Maybe`, or an application's own `data` type), or a function/closure
argument/return -- deliberately out of scope, still narrower than
`%foreign`'s own vocabulary (`Compiler.CompileExpr.nfToCFType`/
`getCFTypes` upstream, not reused here since those also accept
`CFFun`/`CFUser`/`CFBuffer`/`CFForeignObj`). See "Two scope items not
implemented" below.

A declaration outside this scope still fails immediately and
attributably, at compile time, with the offending argument position(s)
or return type named in the error -- not a downstream linker mystery.
Reconstructed from the current `exportSupportedTypesDesc`/
`validateExport` source (not re-verified against a fresh compile for
this update -- unlike the scalar-only-era version of this example,
which was empirically checked when this was the only unsupported
shape):

```
Error: [rc2] %export declaration <name> (Main.bad)'s own argument(s) [0]
own type isn't a type %export supports -- %export supports scalar
(Int/Int8/Int16/Int32/Int64/Bits8/Bits16/Bits32/Bits64/Double/Char), Ptr,
GCPtr, Integer, String, or struct (Struct) arguments
```

### Ptr/AnyPtr and structs (by pointer)

Both directions, argument and return, through exactly the same generic
`packCFType`/`extractValue` round trip `%foreign` already uses for
`CFPtr` -- `emitExportWrapper` needed no special-casing for either.
`rc2/tests/Test60ExportPtr.idr`'s `identityPtr : AnyPtr -> AnyPtr` is
called from plain C with a raw, non-Idris-owned pointer; the companion
C checks both that the exact same address comes back and that the
memory behind it is still readable (i.e. not freed by the wrapper's own
drop-after-return step, since a plain `CFPtr` carries no finalizer for
that step to invoke).

A `Struct "name" [...]`-typed export uses this same mechanism, not a
separate one -- `EmitUtil`'s `cTypeOfCFType`/`extractValue`/
`packCFType` all alias their `CFStruct` case verbatim to `CFPtr`'s. One
caveat carries over from `%foreign`'s own struct support: the struct's
C typedef is only emitted (`Compiler.RC2.Emit`'s `StructDefs`) when a
live `%foreign` declaration using that same struct name exists
somewhere in the program -- an `%export` reference to the struct is not
by itself enough to keep the typedef alive. `Test61ExportStruct.idr`
shows the pattern in practice: its `getXExport`/`scalePoint` exports
are the only things that structurally need the `"test_point"` struct,
but the file also keeps a `%foreign`-bound `prim__makePoint`/
`prim__freePoint` pair (declared over that same struct) referenced from
`main`, purely so `Compiler.RC2.DeadCode.pruneDeadDefs` doesn't strip
them -- and the struct typedef along with them -- out from under the
exports.

### GCPtr/GCAnyPtr: argument position only

Accepted as an **argument** (`Test62ExportGCPtr.idr` wraps a raw,
Idris-unaware pointer via `packCFType CFGCPtr`'s own
`idris2rc2_mkGCPointer(raw, NULL)` -- no finalizer attached, since the
pointer isn't Idris-owned to begin with) but rejected as a **return**
type at compile time, with:

```
[rc2] %export declaration <name> (Main.f)'s own return type is a
GC-managed pointer (GCPtr/GCAnyPtr) -- returning one via %export isn't
supported: the wrapper's own drop-after-return step could invoke the
pointer's finalizer (if one is attached) before the C caller ever sees
the value
```

The hazard is specific to the return position: `emitExportWrapper`
unconditionally `idris2rc2_drop`s its own trampolined result right
after reading its native payload out (see "Memory" below), and a
`GCPtr` can carry an attached finalizer that a drop-to-zero triggers --
for a *returned* pointer, that finalizer could run before the C caller
has even seen the value, a use-after-free. An argument-position
`GCPtr` never risks this, because the wrapper only ever drops its own
return value, never its own arguments.

### Integer (GMP), both directions

`Integer` round-trips through GMP's `mpz_t` in both directions, but
neither direction reuses the generic `packCFType`/`extractValue` path
unmodified:

- **Argument**: the incoming value is a raw `mpz_t`, not already an
  `IDRIS2RC2_Integer*` the way `packCFType CFInteger`'s own identity
  passthrough assumes (that assumption holds everywhere else, where an
  `IDRIS2RC2_Integer` was already built by prior generated code). A new
  helper, `idris2rc2_mkIntegerFromMpz` (`rc2/support/rc2/memory.c`/
  `.h`), copies it in first:

  ```c
  IDRIS2RC2_Integer *idris2rc2_mkIntegerFromMpz(mpz_t src) {
    IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
    mpz_set(v->v, src);
    return v;
  }
  ```

  `emitExportWrapper`'s own `argPack` special-cases `CFInteger` to call
  this instead of the generic `packCFType`.

- **Return**: GMP's `mpz_t` has no by-value C return shape at all, so
  an `Integer`-returning export's whole wrapper signature gains a
  leading `mpz_t out` parameter and its own C return type becomes
  `void` -- mirroring `emitGenericForeignWrapper`'s own identical
  out-parameter convention for a `%foreign`-side Integer return (see
  `Test54FFIInteger`). The body is `mpz_init(out); mpz_set(out,
  <extracted value>);` followed by an explicit `idris2rc2_drop` of the
  trampolined boxed result and a bare `return;`.

Adapted from `rc2/tests/Test63ExportInteger/`, which exercises both
directions with values well outside `Int`'s 64-bit range:

`Test63ExportInteger.idr`:

```idris
%export "C:idris2rc2_test63_add"
addInteger : Integer -> Integer -> Integer
addInteger x y = x + y
```

`Test63ExportInteger.h` (`out` is the *first* parameter, matching
GMP's own convention):

```c
extern void idris2rc2_test63_add(mpz_t out, mpz_t x, mpz_t y);
```

Companion C, calling with values GMP-correct but out of `Int64` range:

```c
mpz_t a, b, out;
mpz_init_set_str(a, "123456789012345678901234567890", 10);
mpz_init_set_str(b, "1", 10);
mpz_init(out);
idris2rc2_test63_add(out, a, b);
/* out == 123456789012345678901234567891 */
```

Same build recipe as "Worked example" above (companion `.c` compiled
to a `.o`, pointed at via `IDRIS2_LDFLAGS`), with `gmp` already on the
`nix-shell -p gcc gmp pkg-config` line rc2 itself needs. Expected
output (`rc2/tests/Test63ExportInteger/Test63ExportInteger.expected`):

```
42
1
```

(`42` = `addInteger 40 2` called ordinarily from Idris; `1` = the
companion C's own GMP-value check succeeded.)

### String: argument and return, different ownership conventions

`isExportableCFType` admits `CFString` in either position, but only
the **return** direction needed a bespoke wrapper path -- an argument
`String` uses the same generic `packCFType CFString` every other
`%foreign`/native-in call site already uses
(`idris2rc2_mkString(varName)`, which copies the incoming `const char
*` into a freshly-owned `IDRIS2RC2_String`), so it carries no special
ownership note beyond that copy. `Test65ExportStringArg` pins this down
directly -- a companion C driver passes a plain string literal (never
Idris/rc2-managed memory) and confirms it's left unmodified after the
call, proving rc2 never aliases or takes ownership of the caller's own
buffer. `Test64ExportString` covers the return direction, which is the
one with a real ownership contract to get right.

**Return** needed a real fix: `extractValue`'s own `CFString` case
aliases the *Boxed* value's own malloc'd buffer directly
(`((IDRIS2RC2_String*)v)->str`) rather than copying it -- returning
that pointer and *then* dropping the Boxed value it came from (the
wrapper's usual post-return cleanup) would hand the C caller a dangling
pointer. `emitExportWrapper`'s `CFString` return case instead:

```c
IDRIS2RC2_Value *r = idris2rc2_trampoline(<call>);
const char *raw = ((IDRIS2RC2_String*)r)->str;
size_t len = strlen(raw) + 1;
char *result = malloc(len);
memcpy(result, raw, len);
idris2rc2_drop(r);
return result;
```

The wrapper's own C return type for this case is plain `char *` --
**not** `const char *` (the usual `cTypeOfCFType CFString` mapping,
meant for `%foreign`'s borrowed-immutable-view convention) -- because
the buffer is now an independent, caller-owned allocation, and a
`const` qualifier on a pointer the caller is expected to `free()` would
be actively misleading.

**Ownership contract**: the returned `char *` is a plain, independent
`malloc`'d buffer. The C caller owns it outright and **must** `free()`
it themselves once done; it must never be passed to any `idris2rc2_*`
function (it is not an `IDRIS2RC2_String` and carries none of that
type's header).

Adapted from `rc2/tests/Test64ExportString/`:

```idris
%export "C:idris2rc2_test64_greet"
greet : Int -> String
greet n = "hello " ++ show n
```

```c
// Test64ExportString.h
extern char *idris2rc2_test64_greet(int64_t n);
```

```c
// companion C
char *s = idris2rc2_test64_greet(9);
int64_t ok = (strcmp(s, "hello 9") == 0);
free(s);   // caller's responsibility -- see ownership contract above
```

Expected output (`Test64ExportString.expected`):

```
hello 7
1
```

(`hello 7` = `greet 7` called ordinarily from Idris via `putStrLn`;
`1` = the companion C's own `strcmp`-and-`free` check succeeded.)

### Buffer: still out of scope

`Buffer` is not supported in either direction. It shares the same
ownership hazard `String`'s return convention above had to solve
explicitly (who allocates it, who frees it, with which allocator), plus
one `String` doesn't have: a `Buffer`'s size isn't self-describing the
way a NUL-terminated `char *` is, so crossing the `%export` boundary
would also need some convention for communicating its length to the C
caller (an out-parameter, a fixed max, a length-prefix convention...)
that hasn't been designed yet. May be revisited later.

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
accident. `CFInteger` and `CFString` returns don't go through this
generic path at all -- see their own dedicated sections under "Scope"
above -- but both still end with an explicit `idris2rc2_drop` of the
trampolined boxed result before the wrapper returns to its caller, for
the same leak-prevention reason.

## Two scope items not implemented (v1)

- **No generated C header.** The wrapper's own prototype has to be
  hand-declared `extern` by whatever C code calls it (see
  `rc2/tests/Test59ExportScalar.h` for the pattern) -- rc2 doesn't
  emit a `.h` of its own alongside the generated `.c` yet.
- **Still a bounded scope**, per "Scope" above -- scalars, `Ptr`/
  `AnyPtr`, `GCPtr`/`GCAnyPtr` (argument-only), `Integer`, `String`,
  and structs-by-pointer are now supported, but `Buffer`, any other
  user-defined ADT (`List`, `Maybe`, or an application's own `data`
  type), and function/closure arguments or returns are still not
  (all of which `%foreign` already supports, in the opposite
  direction, for at least some of these).

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

Six more tests cover the wider scope added afterward, each with a
companion `.c`/`.h` calling the export as plain C: `Test60ExportPtr`
(`CFPtr`, both directions, address-identity and liveness checked),
`Test61ExportStruct` (`CFStruct`, by pointer, plus the struct-typedef
liveness caveat noted under "Scope" above), `Test62ExportGCPtr`
(`CFGCPtr`, argument only), `Test63ExportInteger` (`CFInteger`, both
directions, GMP-range values; also in `verify.sh`'s
`LEAK_SENSITIVE_TESTS`), `Test64ExportString` (`CFString` return and
its caller-`free()`s ownership contract; also `LEAK_SENSITIVE_TESTS`),
and `Test65ExportStringArg` (`CFString` argument, confirming the
caller's own buffer is copied, never aliased or freed by rc2; also
`LEAK_SENSITIVE_TESTS`).
