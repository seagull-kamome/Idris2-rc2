# Emit-time interception of `fastPack`/`fastConcat`/`fastUnpack`/`Data.String.Iterator`

Write-up of the fix for the leak `fastPack`/`fastConcat` had, including why
the first attempt at fixing it (`Prelude.Fix.RC2` + `%transform`) fell
short, the actual Emit-time redirect that replaced it, and a second,
unrelated bug (an empty-string SIGSEGV) found while making the fix
unconditional project-wide. The same Emit-time mechanism was later
widened to also divert `fastUnpack` and `Data.String.Iterator`'s
`uncons`/`withIteratorString` — not a leak, but the same underlying
cause (a `char *`-typed upstream FFI signature) losing information once
`String` could hold an embedded NUL byte; see "Extended to `fastUnpack`
and `Data.String.Iterator`" below. No code from this write-up is
pending — everything described here is implemented and verified (full
`rc2/tests/verify.sh`: 82 passed, 0 known, 0 failed; `libs/rc2base/tests/verify.sh`:
all PASS).

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

## The actual fix: Emit-time interception

Since the frontend can't reach these call sites, the fix moves the
interception to rc2's own C-emission time, in `Compiler.RC2.Emit`. rc2's
backend processes the full `RCDef` set for a compiled program regardless
of which package each definition originated from — so a check made at
this stage sees every call site, including ones already baked into
precompiled `network`/`base` code, with no recompilation of those
packages needed.

`fastPackFixedReplacement : Name -> Maybe String` (`Emit/Foreign.idr`)
matches the definition's **full namespace-qualified name**:

```idris
fastPackFixedReplacement : Name -> Maybe String
fastPackFixedReplacement (NS ns (UN (Basic "fastPack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastPackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastConcat"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastConcatFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastUnpack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastUnpackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "uncons"))) =
    if ns == mkNamespace "Data.String.Iterator" then Just "idris2rc2_stringIteratorNextFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "withIteratorString"))) =
    if ns == mkNamespace "Data.String.Iterator" then Just "idris2rc2_stringIteratorToStringFixed" else Nothing
fastPackFixedReplacement _ = Nothing
```

Checking the full namespace, not just the base name, is a deliberate
defensive choice: a name-only match would misfire on some unrelated
future function that merely happens to share one of these base names
in a different namespace. `fastPack`/`fastConcat` are diverted because
the real `fastPack`/`fastConcat` leak (see above); `fastUnpack`/
`uncons`/`withIteratorString` are diverted for an unrelated reason —
see "Extended to `fastUnpack` and `Data.String.Iterator`" below.

`emitForeignDef`'s dispatch (`Emit/Foreign.idr`, reached from
`createCFunctions`'s `MkRCForeign` case) adds a **second, independent**
check on the exact signature shape before diverting away from the
normal codegen path:

```idris
fastPackFixedShape : CFType -> List CFType -> Bool
fastPackFixedShape ret fargs = boxedRet ret && all boxedArg fargs
  where
    boxedRet : CFType -> Bool
    boxedRet CFString = True
    boxedRet (CFUser _ _) = True
    boxedRet _ = False

    boxedArg : CFType -> Bool
    boxedArg CFString = True
    boxedArg (CFUser _ _) = True
    boxedArg (CFFun _ _) = True
    boxedArg _ = False

case (fastPackFixedReplacement n, fastPackFixedShape ret fargs) of
     (Just fixedFnName, True) => emitFastPackFixedWrapper fixedFnName
     _ => emitGenericForeignWrapper
```

`fastPackFixedShape` accepts any mix of `CFString`/`CFUser` (return)
and `CFString`/`CFUser`/`CFFun` (each argument) rather than one exact
arity/type combination, because the five targets above don't all share
one signature the way the original `List Char -> String`/
`List String -> String` pair did — `withIteratorString`'s own signature
also carries a `CFFun`-typed argument (the continuation it calls with
the rest of the string), which the original "single `CFUser` argument"
check would have rejected outright. What every one of the five actually
needs is a signature `emitFastPackFixedWrapper` can render as-is by
passing every argument through as the boxed value it already is (see
"`emitFastPackFixedWrapper`" below); `fastPackFixedShape` is exactly
that predicate, not a stand-in for matching one specific arity. This
remains a real, independent check regardless: a hypothetical name
collision that somehow also lived in the right namespace would still
need a shape `fastPackFixedShape` accepts to be redirected. Both checks
(name and shape) have to hold before `emitFastPackFixedWrapper` runs;
anything else falls through to the untouched
`emitGenericForeignWrapper`. `hasUsableForeignImpl` (also
`Emit/Foreign.idr`) runs the identical pair of checks to decide whether
a `MkRCForeign` declaration is usable at all — the two call sites must
never disagree about which declarations are diverted.

`emitFastPackFixedWrapper` (`Emit/Foreign.idr`) emits **the same external
C name** `emitGenericForeignWrapper` would have produced — so every
existing call site anywhere keeps linking against the same symbol,
completely unmodified. Its own C parameters are always declared
`IDRIS2RC2_Value *`, one per `fargs` entry, regardless of that
argument's own `CFType` — the shared, type-agnostic declaration shape
every wrapper's outer signature already uses for the same reason
(rc2's internal calling convention boxes every argument uniformly; a
`%foreign` argument's *specific* C type only matters once a wrapper's
own body unwraps it, which this one never does). The wrapper's own
*body* differs from the generic path: it casts each already-boxed
argument straight to `(IDRIS2RC2_Value*)` and calls the matched
`fixedFnName` (`idris2rc2_fastPackFixed`, `idris2rc2_fastUnpackFixed`,
...) directly, skipping `packCFType`/`extractValue` entirely (the same
way a bare `CFUser` return already skips them), since every one of
these C functions already takes/returns a fully-formed,
correctly-owned `IDRIS2RC2_Value *` itself. It drops each argument
after the call the same way the generic wrapper would (`removeVars`),
except an argument whose `CFType` is always-unboxed at the C level
(`alwaysUnboxedDropVar`, `Types.alwaysUnboxed`) is filtered out of that
drop list first, since `idris2rc2_drop` on a tagged-pointer value is a
guaranteed no-op with no reason to even emit.

Confirmed by inspecting real generated C for `Test35NetworkLoopback`:
its `Prelude_Types_fastPack` wrapper (emitted for `network`'s own
precompiled `parseIPv4` call site — that package was **not**
recompiled) now calls `idris2rc2_fastPackFixed`, and the leak is gone.

## Extended to `fastUnpack` and `Data.String.Iterator`: embedded-NUL safety, not leaks

`fastUnpack`, `Data.String.Iterator.uncons`, and
`Data.String.Iterator.withIteratorString` are diverted through this
same Emit-time mechanism too, but for a reason unrelated to the leak
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
Test124StringNul` is the regression test covering all five diverted
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

## `Prelude.Fix.RC2` retired

`libs/rc2base/src/Prelude/Fix/RC2.idr` was deleted (removed from
`rc2base.ipkg`'s `modules`; its now-unnecessary `import` also removed
from `rc2/tests/Test28Utf8Strings.idr`). The Emit-time fix is strictly
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
type-level one — nothing stops a future change to `Emit/Foreign.idr`
from narrowing `fastPackFixedReplacement`'s match (or otherwise breaking the
redirect) without anyone noticing immediately. If that ever happens,
generated code would fall through to `emitGenericForeignWrapper` and
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
Emit-time redirect made `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` unconditional
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
`concat []` through the fixed path. Once the Emit-time redirect made
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

- `rc2/src/Compiler/RC2/Emit/Foreign.idr` — `fastPackFixedReplacement`,
  `fastPackFixedShape`, `emitForeignDef`'s dispatch,
  `emitFastPackFixedWrapper`, `hasUsableForeignImpl`.
- `rc2/support/rc2/idris2rc2_strings.c` — `idris2rc2_fastPackFixed`/
  `idris2rc2_fastConcatFixed` (the empty-string trailing-NUL-write
  removal), `idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/
  `idris2rc2_stringIteratorToStringFixed` (the embedded-NUL-safe
  replacements for `fastUnpack`/`Data.String.Iterator.uncons`/
  `withIteratorString`).
- `rc2/support/rc2/idris2rc2_strings.h` — the retained `deprecated`
  attributes on `fastPack`/`fastConcat` (messages updated to describe
  reaching them as an rc2 bug, not a caller workaround); the
  declarations of the five `*Fixed` replacements above.
- `rc2/support/rc2/idris2rc2_datatypes.h` — `IDRIS2RC2_String`'s own
  `len` field, the reason `fastUnpack`/`uncons`/`withIteratorString`
  needed diverting at all (`rc2/doc/constructor-layout.md`, "Strings").
- `rc2/src/Compiler/RC2/CC.idr` — the retained
  `-Wno-error=deprecated-declarations` flag.
- `rc2/tests/Test46FastPackUnconditional.idr` — regression test for the
  original leak fix.
- `rc2/tests/Test124StringNul/` — regression test covering all five
  diverted functions against a `String` holding an embedded NUL byte.
- `libs/rc2base/src/Prelude/Fix/RC2.idr` — **no longer exists**
  (retired; removed from `rc2base.ipkg`'s `modules`, its import removed
  from `rc2/tests/Test28Utf8Strings.idr`).
