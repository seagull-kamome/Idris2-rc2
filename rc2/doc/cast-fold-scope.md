# Cast constant folding: excluded directions and why (investigated, not pursued further)

`Compiler.RC2.ConstFold`'s `foldableOp` (see its own doc comment) folds
`Cast` only for fixed-width int/`Integer` operands on both sides, plus
fixed-width int/`Integer` -> `String`. This document records why three
further directions -- `Char -> String`, `Double -> String`, and any
`String`-sourced `Cast` -- were investigated and found unsafe to fold,
so a future session doesn't have to re-derive any of this before
touching `foldableOp` again.

## `Char -> String`: `stripQuotes` mishandles multi-character escapes

Upstream `Core.Primitives.getOp`'s `Cast` dispatch ignores the source
type and dispatches purely on the target (`getOp (Cast _ y) = castTo
y`, `idris2-src/src/Core/Primitives.idr:610`). `castTo StringType =
castString` (`Primitives.idr:551,563`), and `castString`'s `Ch` case
(`Primitives.idr:42`) is:

```idris2
castString [NPrimVal fc (Ch i)] = Just (NPrimVal fc (Str (stripQuotes (show i))))
```

`stripQuotes` (`idris2-src/src/Libraries/Utils/String.idr:10-11`)
strips exactly one character off each end. That's correct for a plain
printable character (`show 'A' = "'A'"`, stripped to `"A"`), but
`Show Char`'s own escaping (`libs/prelude/Prelude/Show.idr`,
`showLitChar`) renders every codepoint above `'\DEL'` (0x7F), plus
named control characters like `'\n'`, as a **multi-character** escape
sequence: `show '\n' = "'\n'"` (backslash-n, two characters inside the
quotes), `show` of codepoint 0x3042 (`'あ'`) similarly escapes to a
multi-character numeric form. `stripQuotes` only ever removes one
character per end, so for any such codepoint the result is the escape
sequence's own text (e.g. backslash followed by `n`), not the actual
character. `Compiler.RC2.ConstFold.constFoldOp` calls upstream's
`getOp` unmodified (no reimplementation), so folding `Cast CharType
StringType` would inherit this bug verbatim -- confirmed by hand: `cast
'あ'` folded through `castString` would yield the wrong multi-byte
escape text instead of the correct UTF-8 encoding rc2's own runtime
(`support/rc2/numeric.c`'s `idris2rc2_cast_Char_to_string`, a plain
codepoint-to-UTF8-bytes encoder with no escaping at all) produces.

`foldableOp`'s `Cast from StringType` case is gated on `isJust (intKind
from)`, and `intKind CharType = Nothing`, so this exclusion is already
automatic -- there's no separate `Cast CharType StringType = False`
clause to maintain. The risk this document flags is specifically that
a future "simplification" collapsing `Cast from StringType` into the
generic `isJust (intKind from) && isJust (intKind to)` rule would
*still* exclude `Char` correctly (same reason), so the real risk is
someone fixing the underlying `stripQuotes` bug upstream (or replacing
`castString`'s `Ch` case with a correct implementation) without
rc2 ever re-examining whether it's then safe to widen `foldableOp`.

Test: `rc2/tests/Test17ConstFold.idr`'s `castCharToStringNotFolded`
casts `'あ'` (deliberately a non-ASCII codepoint, not a plain letter --
folding it, if the exclusion ever regressed, would produce a visibly
wrong string instead of coincidentally matching) and checks the
runtime output is the correct UTF-8 encoding.

## `Double -> String`: `%f` vs. host `Show Double` formatting mismatch

`castString`'s `Db` case (`Primitives.idr:41`) is `Str (show i)` --
whatever the host Idris2 compiler's own `Show Double` produces (a
variable-width format, e.g. `3.0` rather than `3.000000`). rc2's own
runtime (`support/rc2/numeric.c`'s Double-to-string cast) uses
`snprintf(..., "%f", v)`, always six fixed decimal digits (`0.0` ->
`"0.000000"`, confirmed against `rc2/tests/Test7CastMatrix.expected`).
These two formats don't agree, so folding would silently produce a
different string at compile time than the runtime cast would produce.

This is already structurally blocked at a different layer:
`ConstFold.safeConst` excludes `Db` from *every* PrimFn, not just
`Cast` (host-width/rounding mismatch risk, same reasoning as excluding
`I`), so `constFoldOp`'s `all safeConst cs` check already refuses to
fold `Cast DoubleType StringType` regardless of what `foldableOp` says.
`foldableOp`'s own `Cast from StringType = isJust (intKind from)` adds
a second, independent block (`intKind DoubleType = Nothing`). Both are
intentional -- don't remove either while the other still stands as the
sole guard; `safeConst` is the one that would need to change first if
this direction is ever revisited, and it can't change without also
reopening the `%f`-vs-`show` formatting question above.

Test: `castDoubleToStringNotFolded` in `Test17ConstFold.idr`.

## `String` as `Cast`'s source (either direction): parser semantics unverified

`Core.Primitives.getOp`'s `Cast` dispatch also admits `String` as a
*source* for several targets -- `castInteger`/`castInt`/`castDouble`
(`Primitives.idr:58,73,140`) all have a `Str` case that parses the
string via the host's own `Prelude.Cast String X` instance
(`prim__cast_StringInteger` etc., a backend-defined primitive).
Whether that parser agrees byte-for-byte with rc2's own runtime parser
(`support/rc2/numeric.c`'s `mpz_set_str`/`atoll`/`atof`-based `String
-> Integer/Int*/Double` casts, none of which do explicit error
handling on malformed input) is unverified -- and there's existing,
concrete evidence the parsers in this ecosystem *don't* always agree:
`rc2/tests/Test7CastMatrix.idr`'s own header comment (lines 15-19)
notes that rc2's `String -> Int64/Bits64` casts deliberately parse via
`atoll` rather than reproducing RefC's `atoi`-based (and therefore
32-bit-limited) version of the same cast, and keeps its own test
values within `atoi`'s range specifically to stay comparable across
backends rather than exercise that divergence. If two *runtime*
C-side implementations (rc2's own, RefC's) already disagree on range,
there's no reason to assume the host Idris2 compiler's own evaluator
(whatever backend built it, typically Chez) agrees with either at
compile time.

Also note `getOp`'s own `castBits8`/`castInt8`/etc. (the fixed-width
integer targets, via `constantIntegerValue`,
`Primitives.idr:76-87`) have **no** `Str` case at all -- `String ->
Bits8` and friends already return `Nothing` from `getOp` itself,
independent of anything `foldableOp` does. Only `String -> Integer/Int
(unsuffixed)/Double` are live enough at the `getOp` layer to need an
explicit exclusion, and `Int`/`Double` are already excluded on other
grounds (`Cast _ IntType = False`, `intKind DoubleType = Nothing`).
`String -> Integer` is the one combination that's both live at the
`getOp` layer and not otherwise excluded, so `foldableOp`'s general
`Cast from to = isJust (intKind from) && isJust (intKind to)` rule
handles it correctly today (`intKind StringType = Nothing`) -- but,
same caution as the `Char` case above, this is a side effect of
`intKind`'s current definition, not a hand-maintained safety check, so
don't assume it stays excluded if `intKind` or the general rule ever
changes shape.

Test: `castStringToIntegerNotFolded` in `Test17ConstFold.idr`.

## Files

- `rc2/src/Compiler/RC2/ConstFold.idr` -- `foldableOp`'s own doc
  comment carries the short version of this reasoning; this document
  is the full write-up.
- `idris2-src/src/Core/Primitives.idr` -- `castString`/`castTo`/
  `castInt`/`castInteger`/`castDouble`, lines ~31-160, 550-613.
- `idris2-src/libs/prelude/Prelude/Show.idr` -- `Show Char`'s own
  multi-character escaping (`showLitChar`).
- `idris2-src/src/Libraries/Utils/String.idr` -- `stripQuotes`.
- `rc2/support/rc2/numeric.c` -- rc2's own runtime Cast
  implementations (`idris2rc2_cast_Char_to_string`, Double-to-string
  `%f` formatting, `String -> Integer/Int*/Double` parsers).
- `rc2/tests/Test7CastMatrix.idr` -- header comment documents the
  `atoll`-vs-`atoi` String-source divergence and three unrelated
  upstream RefC-runtime bugs found while investigating this area
  (`idris2_cast_Double_to_Int8` missing entirely, `idris2_cast_String_to_*`
  defined with a capital S while RefC's own compiler emits calls to
  the lowercase form, `idris2_negate_Double` typo'd as
  `idris2_nagate_Double`) -- none of these are rc2 bugs.
- `rc2/tests/Test17ConstFold.idr` -- regression tests confirming all
  three directions above stay unfolded.

## Verification methodology (if reopening this)

1. **`Char -> String`**: first confirm whether upstream's `castString`
   `Ch` case (or `stripQuotes`) has been fixed to handle multi-character
   escapes correctly. If so, port the fix's reasoning, don't just widen
   `foldableOp` -- re-derive from `Show Char`'s current escaping rules
   whether every codepoint now round-trips correctly through
   `show`+un-escape, not just ASCII printables.
2. **`Double -> String`**: this can't move without first revisiting
   `safeConst`'s `Db` exclusion project-wide (it excludes `Db` from
   every PrimFn, not just Cast) -- that's a bigger, separate decision.
   If ever taken up, verify `snprintf("%f", ...)` output against the
   host's own `Show Double` output across a boundary-value sweep
   (0.0, negative zero, very large/small magnitudes, values needing
   scientific notation in one format but not the other) before trusting
   any single example.
3. **`String -> Integer`**: write a repro exercising both rc2's
   `mpz_set_str`-based runtime parse and a compile-time `getOp` fold of
   the same literal, across malformed/edge-case inputs (leading `+`,
   whitespace, leading zeros, empty string, overflow) -- not just
   well-formed decimal integers -- and confirm they agree before
   trusting the general `intKind`-based exclusion to keep working if
   `intKind`'s definition ever changes.
4. `--directive dumprcexpr` (see `rc2/doc/reading-the-ir.md`) on any
   repro confirms whether a given `Cast` folded (`RPrimVal`) or stayed
   a runtime `op cast-...` -- the fastest way to check `foldableOp`'s
   actual behaviour without reading generated C.
