# Replacing `char *` string foreigns: `fastPack`, `fastConcat`, `fastUnpack`, `Data.String.Iterator`, `Data.Buffer`'s string primitives

Write-up of the fix for the leak `fastPack`/`fastConcat` had, including why
the first attempt at fixing it (`Prelude.Fix.RC2` + `%transform`) fell
short, the actual redirect that replaced it (first at C emission, now a rewrite of the
declaration), and a second,
unrelated bug (an empty-string SIGSEGV) found while making the fix
unconditional project-wide. The same mechanism was later
widened to also divert `fastUnpack` and `Data.String.Iterator`'s
`uncons`/`withIteratorString` — not a leak, but the same underlying
cause (a `char *`-typed upstream FFI signature) losing information once
`String` could hold an embedded NUL byte; see "Extended to `fastUnpack`
and `Data.String.Iterator`" below. No code from this write-up is
pending — everything described here is implemented and verified (full
`rc2/tests/verify.sh`: 82 passed, 0 known, 0 failed; `libs/rc2base/tests/verify.sh`:
all PASS).

## What is replaced, and why

rc2 rewrites some upstream `%foreign` functions **while it generates the C**:
instead of the C function the declaration names, the program calls a function of
rc2's own that takes the `String` value itself. This is done for two reasons, and
for these functions only (`diverted` in `Compiler/RC2/ForeignDivert.idr` is the
list):

- **Leak.** The generic wrapper of a `%foreign` that returns a `char *` copies the
  result into a new `String` and never frees the original, which is right for a
  library that owns the pointer and wrong for a function that `malloc`s a buffer
  for rc2 alone (`fastPack`, `fastConcat`).
- **Embedded NUL.** rc2's `String` has a length (`IDRIS2RC2_String.len`) and can
  hold NUL bytes. A `%foreign` that takes the `String` as a `char *`, or returns a
  `char *`, loses everything from the first NUL (`strlen`, `strncpy`, the
  constructor that reads a C string). The replacement uses `len` instead.

| upstream function | module | replaced by (rc2) | reason |
|---|---|---|---|
| `fastPack` | `Prelude.Types` | `idris2rc2_fastPackFixed` | leak, and the result's NUL |
| `fastConcat` | `Prelude.Types` | `idris2rc2_fastConcatFixed` | leak, and the result's NUL |
| `fastUnpack` | `Prelude.Types` | `idris2rc2_fastUnpackFixed` | NUL (reads `char *`) |
| `uncons`, `withIteratorString` | `Data.String.Iterator` | `idris2rc2_stringIteratorNextFixed`, `idris2rc2_stringIteratorToStringFixed` | NUL (read `char *`) |
| `uncons`, `withIteratorString` | `Libraries.Data.String.Iterator` (the compiler's own copy, used by `Core.Hash`) | the same two | NUL |
| `stringByteLength` | `Data.Buffer` | `idris2rc2_stringByteLengthFixed` | NUL (`strlen`) |
| `prim__setString` | `Data.Buffer` | `idris2rc2_setBufferStringFixed` | NUL (`strlen` of the argument) |
| `prim__getString` | `Data.Buffer` | `idris2rc2_getBufferStringFixed` | NUL (`strncpy`, then a C string becomes the `String`) |

Why it matters beyond a stray program: the compiler writes and reads the String
constants of a `.ttc` file with exactly the three `Data.Buffer` functions
(`Core.Binary.Prims`, `TTC String`). A compiler **built by rc2** without this
replacement cut every String constant at its first NUL (`rc2/doc/self-hosting.md`,
finding 9).

How it works:

1. **One rewrite of the declaration.** When the program is turned into `RCDef`s
   (`normalizeTop` in `RC.idr`, where a `MkNmForeign` becomes a `MkRCForeign`),
   `divertForeign` (`Compiler/RC2/ForeignDivert.idr`) looks the declaration up in
   the table, by the full namespace and the base name, and by its number of
   arguments. A match is replaced by an ordinary declaration:

   ```
   MkRCForeign <upstream conventions> <argument types> <result type>
     ->
   MkRCForeign ["RC2:idris2rc2_...Fixed"] [CFUser, ...] CFUser      (CFIORes CFUser for a PrimIO)
   ```

   `CFUser` is the one `CFType` that the wrapper passes on exactly as the boxed
   value it already is: no `char *`, no copy, no conversion of the result. That is
   what removes both the leak and the loss at the NUL.
2. **Nothing else knows.** The rest of the compiler sees a `%foreign` with an `RC2:`
   convention and opaque arguments, and treats it like any other: the C emitter writes
   the usual wrapper (same C name as before, so call sites inside precompiled
   `.ttc` link unchanged), and the native-type passes (`DualABI`, `CalleeTable`) leave
   it alone, because a `CFUser` is never unboxed, so its raw C call is never
   put at the call site. A `PrimIO` declaration keeps its `PrimIO` result type, so the
   `%World` token is left out of the C call as for any `PrimIO` declaration; the
   replacements of `prim__setString` and `prim__getString` take three arguments, not
   four, and return `NULL` for the unit.
3. **A declaration with another number of arguments is left alone**, so a function of
   the same name and namespace but another shape is not mangled.

To divert another function: add a row to the table in `ForeignDivert.idr`
(namespace, base name and number of arguments), write the replacement in `idris2rc2_strings.c` or
`idris2rc2_buffer.c` taking the boxed values, declare it in `idris2rc2_strings.h`,
and add a case to `rc2/tests/Test169Strings/StringNul` (for the NUL case) or to the leak
tests. Then add the row above.

## The original leak

`fastPack : List Char -> String` and `fastConcat : List String -> String`
are declared `%foreign "RefC:fastPack"`/`"RefC:fastConcat"` with a
`CFString` return type, so `Compiler.RC2.Emit`'s generic FFI-wrapper
codegen (the path every other `%foreign` declaration goes through) wraps
whatever `char *` the C implementation returns by copying it into a
fresh `IDRIS2RC2_String` via `idris2rc2_mkString` (`rc2/support/rc2/memory.c`)
— and never frees the original pointer.

That's the *correct* protocol for the common case: a real external
library's own `char *` return (e.g. `curl_easy_strerror`) must not be
freed by the caller, since the library owns it. It's wrong for
`fastPack`/`fastConcat` specifically: both `malloc` a buffer this
project itself owns (`rc2/support/rc2/idris2rc2_strings.c`'s `fastPack`/
`fastConcat`), built solely to be copied once and then discarded. The
generic wrapper has no way to know that distinction from the FFI
signature alone — a `CFString`-returning foreign function looks
identical whether the underlying buffer is borrowed or owned.

## First attempt: `Prelude.Fix.RC2` + `%transform` (insufficient)

The first fix added leak-free replacements, `idris2rc2_fastPackFixed`/
`idris2rc2_fastConcatFixed` (still in `idris2rc2_strings.c`), each building
directly into a fresh `IDRIS2RC2_String` and returning an
already-fully-formed `IDRIS2RC2_Value *` — no intermediate `char *` for
anything to copy-and-leak. These were wired in via a
`libs/rc2base/src/Prelude/Fix/RC2.idr` module using upstream Idris2's own
`%transform` mechanism to rewrite calls to `fastPack`/`fastConcat` into
calls to the fixed versions.

This worked, but only for a program that explicitly `import`ed that
module. The architectural reason is fundamental, not a bug in how the
module was written: `%transform` rewrites a call site only within the
rewriting definition's own elaboration/import scope, at elaboration
time. It has no way to reach a call site that's already baked into
another package's own separately-compiled `.ttc` — the rewrite has to be
*in scope* at the point the call is elaborated, and `network`/`base`
were elaborated (and shipped as `.ttc`) long before this project's own
`%transform` rule could ever be in scope for them.

This left two tests carrying a `KNOWN_LEAK_BYTES` entry in `verify.sh`,
neither fixable from the frontend side no matter what a caller
`import`ed:

- `Test35NetworkLoopback` — leaks via `network`'s own
  `Network.Socket.Data.parseIPv4`, which calls `fastPack` internally.
- `Test37SystemMisc` (formerly `Test40SystemProcess`) — leaks via
  `base`'s own `System.File.ReadWrite`'s `fRead'`, which calls
  `fastConcat` internally.

## The fix: rewrite the declaration

Since the frontend can't reach these call sites, the fix lives in rc2's own
backend, which processes the full `RCDef` set for a compiled program regardless of
which package each definition originated from. A change made there sees every
call site, including ones already baked into precompiled `network`/`base` code, with
no recompilation of those packages needed.

It was first done at C emission: a table in `Emit/Foreign.idr`, a check of the
signature's shape, and a wrapper of its own (`emitFastPackFixedWrapper`). That worked
for the String-only functions, but when `Data.Buffer`'s `Int`- and `Buffer`-taking
functions joined the list, the raw C call of a scalar `%foreign` was still put at
the call site by the dual-ABI pass (`strlen(...)` stayed `strlen(...)`), and keeping
the diverted ones out of it meant teaching `DualABI` and `CalleeTable` about the
list. The list was moved to one place instead: `divertForeign` rewrites the
declaration itself, early, and the three emission and optimisation passes need no
special case (the dedicated wrapper, the shape check and the two exceptions in
`DualABI`/`CalleeTable` are gone). See "What is replaced, and why".

Checking the full namespace, not just the base name, is a deliberate defensive
choice: a name-only match would misfire on some unrelated future function that
merely happens to share one of these base names in a different namespace.

Confirmed by inspecting real generated C for `Test35NetworkLoopback`: its
`Prelude_Types_fastPack` wrapper (emitted for `network`'s own precompiled `parseIPv4`
call site — that package was **not** recompiled) calls `idris2rc2_fastPackFixed`, and
the leak is gone.

## Extended to `fastUnpack` and `Data.String.Iterator`: embedded-NUL safety, not leaks

`fastUnpack`, `Data.String.Iterator.uncons`, and
`Data.String.Iterator.withIteratorString` are diverted through this
same mechanism too, but for a reason unrelated to the leak
above: none of the three leaks anything. Their upstream `%foreign`
declarations take the string as a plain `char *` (`fastUnpack(char
*str)`, `stringIteratorNext(char *s, ...)`,
`stringIteratorToString(void *a, char *str, ...)`, all still in
`idris2rc2_strings.h`/`.c`) — since rc2's own `String` can now hold an
embedded NUL byte (`rc2/doc/constructor-layout.md`, "Strings"), reading
one of these through `->str` alone loses everything from the first
embedded NUL onward, silently: `fastUnpack "ab\NUL1cd"` would unpack to
just `"ab"`, `Data.String.Iterator`'s own fold would stop at the same
point.

`idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/
`idris2rc2_stringIteratorToStringFixed` (`idris2rc2_strings.c`) fix
this the same way `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`
avoid the copy-and-leak above: by taking the `IDRIS2RC2_Value *`
itself, cast back to `IDRIS2RC2_String *`, and reading `->len` bytes
from `->str` rather than reading `->str` until a NUL. `rc2/tests/
Test169Strings/StringNul` is the regression test covering all the diverted
functions (plus `Data.TextBuffer.fromString`, which reaches C through a
different mechanism — see `libs/rc2base/README.md`'s own
`Data.String.RC2`/`Data.TextBuffer` coverage) against a `String`
carrying an embedded NUL byte.

Unlike `fastPack`/`fastConcat` above, `fastUnpack`/`stringIteratorNext`/
`stringIteratorToString` carry no `deprecated` attribute in
`idris2rc2_strings.h` — reaching one of them isn't a leak, just a
silent truncation at the first embedded NUL, so there's no matching
"this should be unreachable" build-time signal to attach one to; the
redirect here is the only thing standing between the diverted call
sites and that truncation.

## Extended to `Data.Buffer`'s string primitives and `Libraries.Data.String.Iterator`

Found by building the compiler with rc2 (`rc2/doc/self-hosting.md`): the
rc2-built compiler gave other C than the Chez-built one for a program with a NUL in a
String literal (`rc2/tests/Test169Strings/StringNul`, 1190 lines of difference). The String
constant was cut in the `.ttc` code, which writes and reads Strings with
`Data.Buffer.stringByteLength`, `prim__setString` and `prim__getString`. Their
`RefC:` implementations work on a `char *` (`setBufferString` takes the length with
`strlen`, `getBufferString` copies with `strncpy` and returns a C string that the
wrapper turns into a `String` with `strlen`), and `stringByteLength` is libc's
`strlen` itself.

The three are diverted like the others, with `idris2rc2_stringByteLengthFixed`,
`idris2rc2_setBufferStringFixed` and `idris2rc2_getBufferStringFixed`
(`idris2rc2_buffer.c`, which can check the range with the file's own
`assert_valid_range`). They take the boxed `String`, `Int` and `Buffer`, use
`->len`, and return the `Int`, `NULL` (unit) or `String` boxed.

One change to the mechanism came with it. At first the replacement was not reached:
`DualABI` and `CalleeTable` put the raw C call of a foreign function with a scalar
argument or result at the call site (`RAppFFIInline`), so `strlen(...)` was still
there and the replaced wrapper was never called. Special cases in those passes would
have spread the list into them, so the replacement became a rewrite of the declaration
(`ForeignDivert`) instead, which those passes do not see through: an opaque (`CFUser`)
declaration is never inlined. The cost is that these functions are no longer inlined
as raw C calls; the call goes through the wrapper.

`Libraries.Data.String.Iterator` is the compiler's own copy of
`Data.String.Iterator` (only `Core.Hash` uses it); its `uncons` and
`withIteratorString` have the same shape and go to the same two replacements.

Behaviour that changes: `getString` gives exactly the requested number of bytes
(the Chez backend's meaning) instead of the bytes up to the first NUL, and
`setString` writes all the bytes of the `String`.

`rc2/tests/Test169Strings/StringNul` has the round trip with a NUL and a digit after it, and
`rc2/tests/selfhost.sh diff` compares the C that the Chez-built and the rc2-built
compiler give for all of `rc2/tests`.

## `Prelude.Fix.RC2` retired

`libs/rc2base/src/Prelude/Fix/RC2.idr` was deleted (removed from
`rc2base.ipkg`'s `modules`; its now-unnecessary `import` also removed
from `rc2/tests/Test28Utf8Strings.idr`). The redirect is strictly
more general — it covers every call site the `%transform` module covered
plus every one it couldn't reach — so keeping the opt-in module around
would only be redundant.

## Why the `deprecated` attribute was kept, not removed

`idris2rc2_strings.h` still declares `fastPack`/`fastConcat` with
`__attribute__((deprecated(...)))`, and `rc2/src/Compiler/RC2/CC.idr`
still passes `-Wno-error=deprecated-declarations` when compiling
generated C. Both were deliberately **kept** as a safety net rather than
cleaned up now that the redirect makes them supposedly unreachable in
practice.

The reasoning: the redirect is a codegen-level guarantee, not a
type-level one — nothing stops a future change to `ForeignDivert.idr`
from narrowing `divertedFunction`'s match (or otherwise breaking the
redirect) without anyone noticing immediately. If that ever happens,
generated code would keep the upstream declaration and
start calling the real, leaking `fastPack`/`fastConcat` again — silently
correct-looking, but leaking. Keeping the `deprecated` attribute means
that regression would reappear as a **build-time warning** (suppressed
from being a hard error only by the explicit
`-Wno-error=deprecated-declarations` flag, so it never blocks a build,
but still visible to anyone reading build output) rather than a silent
leak discovered again only by chance under `valgrind`. Both attribute
messages were updated (by the implementing session) to say that reaching
them now indicates an rc2 bug in the redirect, not something a caller
needs to work around.

## Second bug found along the way: empty-string SIGSEGV

Not part of the original plan — discovered during verification once the
redirect made `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` unconditional
project-wide.

**Root cause**: both functions used to do an explicit
`r->str[byteLen] = '\0'` (`byteLen`/`total` being the computed output
length) after `idris2rc2_mkEmptyString(byteLen + 1)`. For the
empty-input case (`byteLen == 0`, e.g. `pack []`/`concat []`),
`idris2rc2_mkEmptyString(1)` doesn't allocate a fresh buffer at all — it
returns the shared immortal `const` static `idris2rc2_emptyStringValue`.
Writing to `r->str[0]` in that case is a write into read-only memory.

This was invisible while the fix was still opt-in-only via
`Prelude.Fix.RC2`: no existing importer ever called `pack []`/
`concat []` through the fixed path. Once the redirect made
these unconditional for every project, `refc-suite`'s own `strings` test
(which does exactly this) crashed with a SIGSEGV.

**Fix**: delete both trailing-NUL writes. `idris2rc2_mkEmptyString`'s
own malloc'd path already `memset()`s the whole buffer to zero, so the
terminator byte (right after the last one the copy loop writes) was
always already correct without an explicit write. This matches the
pattern every other `idris2rc2_mkEmptyString` caller in
`idris2rc2_strings.c` already follows (`idris2rc2_strTail`/`strReverse`/
`strCons`/`strAppend`/`strSubstr` — none of them do an indexed write
past their own `memcpy`'d payload either).

## Verification methodology

1. Full `rc2/tests/verify.sh`: 82 passed, 0 known, 0 failed.
2. Full `libs/rc2base/tests/verify.sh`: all PASS.
3. Inspected real generated C for `Test35NetworkLoopback` (an
   unmodified precompiled `network`-package call site into
   `parseIPv4`) and confirmed its `Prelude_Types_fastPack` wrapper calls
   `idris2rc2_fastPackFixed`, with no recompilation of `network`/`base` needed
   anywhere.
4. `verify.sh`'s `KNOWN_LEAK_BYTES` map is now genuinely empty — the
   `Test35NetworkLoopback`/`Test37SystemMisc` (then `Test40SystemProcess`) entries were removed,
   both confirmed 0 leaked bytes. (`Test35NetworkLoopback` remains in
   `NO_REFC_DIFF_TESTS` for a completely unrelated, still-open reason: a
   real-RefC-only compile bug in `parseIPv4`'s own generated
   cast-function-name casing mismatch — nothing to do with this fix.)
5. New regression test: `rc2/tests/Test46FastPackUnconditional.idr`
   (+ `.expected`), calling `pack`/`concat` with zero opt-in imports —
   registered in `verify.sh`'s `LEAK_SENSITIVE_TESTS`, confirmed
   leak-free. Its own module comment also covers the empty-string case
   implicitly by calling `pack`/`concat` on non-empty lists; the
   empty-input SIGSEGV was caught by `refc-suite`'s pre-existing
   `strings` test, not a new dedicated test, since that test already
   happened to exercise `pack []`/`concat []`.

## Files

- `rc2/src/Compiler/RC2/ForeignDivert.idr` — the table (`diverted`) and the
  rewrite (`divertForeign`, `divertedFunction`); called from `normalizeTop` in
  `rc2/src/Compiler/RC2/RC.idr`. The only place that knows which functions are
  replaced.
- `rc2/support/rc2/idris2rc2_buffer.c` — `idris2rc2_stringByteLengthFixed`,
  `idris2rc2_setBufferStringFixed`, `idris2rc2_getBufferStringFixed`.
- `rc2/support/rc2/idris2rc2_strings.c` — `idris2rc2_fastPackFixed`/
  `idris2rc2_fastConcatFixed` (the empty-string trailing-NUL-write
  removal), `idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/
  `idris2rc2_stringIteratorToStringFixed` (the embedded-NUL-safe
  replacements for `fastUnpack`/`Data.String.Iterator.uncons`/
  `withIteratorString`).
- `rc2/support/rc2/idris2rc2_strings.h` — the retained `deprecated`
  attributes on `fastPack`/`fastConcat` (messages updated to describe
  reaching them as an rc2 bug, not a caller workaround); the
  declarations of the `*Fixed` replacements above.
- `rc2/support/rc2/idris2rc2_datatypes.h` — `IDRIS2RC2_String`'s own
  `len` field, the reason `fastUnpack`/`uncons`/`withIteratorString`
  needed diverting at all (`rc2/doc/constructor-layout.md`, "Strings").
- `rc2/src/Compiler/RC2/CC.idr` — the retained
  `-Wno-error=deprecated-declarations` flag.
- `rc2/tests/Test46FastPackUnconditional.idr` — regression test for the
  original leak fix.
- `rc2/tests/Test169Strings/StringNul.idr` — regression test covering the diverted
  functions (`fastPack`/`fastUnpack`, the iterators, `Data.Buffer`'s three) against a
  `String` holding an embedded NUL byte.
- `rc2/tests/selfhost.sh diff` — compares the C of `rc2/tests` from the Chez-built
  and the rc2-built compiler.
- `libs/rc2base/src/Prelude/Fix/RC2.idr` — **no longer exists**
  (retired; removed from `rc2base.ipkg`'s `modules`, its import removed
  from `rc2/tests/Test28Utf8Strings.idr`).
