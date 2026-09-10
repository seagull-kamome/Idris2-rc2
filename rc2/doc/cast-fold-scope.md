# Cast constant folding: excluded directions and why (investigated, not pursued further)

`Compiler.RC2.ConstFold`'s `foldableOp` (see its own doc comment) folds
`Cast` only for fixed-width int/`Integer` operands on both sides, plus
fixed-width int/`Integer` -> `String`. This document records why three
further directions -- `Char -> String`, `Double -> String`, and any
`String`-sourced `Cast` -- were investigated and found unsafe to fold,
so a future session doesn't have to re-derive any of this before
touching `foldableOp` again. A fourth section covers the reverse case:
`Double` arithmetic and `int -> Double`, which *are* safe to fold but
are currently held back by the same blanket `safeConst` `Db` exclusion.

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

## `Double -> String`: host `Show Double` vs. rc2's own formatter

`castString`'s `Db` case (`Primitives.idr:41`) is `Str (show i)` --
whatever the *host* Idris2 compiler's own `Show Double` produces
(typically Chez's `number->string`). rc2's own runtime
(`support/rc2/numeric.c`'s `idris2rc2_cast_Double_to_string`) now emits
the shortest decimal that round-trips to the same double -- much closer
to Chez than the old fixed `"%f"` was, but still not guaranteed
character-for-character identical: the exponent-notation threshold is
rc2's own choice (`(-6, 21]` plain, `<m>e<n>` otherwise), and rc2 keeps
a leading `0` on `0.5` where Chez writes `.5`. So folding could still
produce a slightly different string at compile time than the runtime
cast.

This stays blocked at a different layer anyway: `ConstFold.safeConst`
excludes `Db` from *every* PrimFn, not just `Cast` (host-width/rounding
mismatch risk, same reasoning as excluding `I`), so `constFoldOp`'s
`all safeConst cs` check already refuses to fold `Cast DoubleType
StringType` regardless of what `foldableOp` says. `foldableOp`'s own
`Cast from StringType = isJust (intKind from)` adds a second,
independent block (`intKind DoubleType = Nothing`). Both are
intentional -- don't remove either while the other still stands as the
sole guard. Revisiting this direction now needs a smaller check than
before (does rc2's shortest-form formatter agree with the host's across
a boundary-value sweep, exponent-notation and leading-zero conventions
included?), but still starts with `safeConst`'s project-wide `Db`
exclusion.

Test: `castDoubleToStringNotFolded` in `Test17ConstFold.idr`.

## `Double` arithmetic and `Int`/`Integer` -> `Double`: fold-safe, held back only by `safeConst`'s blanket `Db`

`safeConst (Db _) = False` is a single blunt switch that stops
`constFoldOp` folding **any** PrimFn whose operands include a `Db`
literal -- not just the two `Cast` directions above but also
`Add`/`Sub`/`Mul`/`Div`/`Neg DoubleType`, the `Double` comparisons,
`DoubleSqrt`/`DoubleFloor`/`DoubleCeiling`, the transcendentals
(`DoubleExp`/`Log`/`Pow`/`Sin`/`Cos`/`Tan`/`ASin`/`ACos`/`ATan`), and
`Cast (fixed-width int / Integer) -> DoubleType`. `getOp` implements
every one of these (`Primitives.idr:212-495`, `castDouble` at
`:129-141`), so the only thing standing between them and a compile-time
fold is that one guard (plus, for the `Cast _ -> Double` shape,
`foldableOp`'s `intKind DoubleType = Nothing`).

Of that set, the arithmetic and comparisons are actually **safe** to
fold: IEEE 754 binary64 add/sub/mul/div/neg and ordered comparison are
bit-exact and identical between the host evaluator (`getOp`'s
`add (Db x) (Db y) = Db (x + y)` etc., whatever backend built the
compiler) and rc2's C runtime (hardware `double`). `DoubleSqrt` is
IEEE-mandated correctly-rounded, and `DoubleFloor`/`DoubleCeiling` are
exact, so those three are safe too. `Cast (fixed-width int / Integer)
-> Double` is round-to-nearest-even by IEEE, agreed on by host and
target (a very large `Integer` only loses precision past 2^53, and
both round it the same way).

What must stay excluded even if the blanket rule is relaxed:

- `Cast DoubleType StringType` and `Cast StringType DoubleType` -- the
  formatter / parser mismatches documented in the two neighbouring
  sections.
- `Cast DoubleType -> (fixed-width int)` -- truncation-toward-zero of
  an out-of-range or NaN operand is platform-defined; already blocked
  for the `Int` target by `Cast _ IntType = False`, but not for
  `Int64`/`Bits64`/etc.
- The transcendentals -- `doubleOp exp` and friends call the *host's*
  libm (via whatever backend built the compiler, e.g. Chez's `flexp`),
  which is not guaranteed to agree with the target's C `libm` to the
  last ULP.

So enabling this is not a one-line change: `safeConst` (or a companion
check in `constFoldOp`) has to become aware of *which* PrimFn it's
guarding, `foldableOp` needs a `Cast from DoubleType = isJust (intKind
from)` clause (written like the `Cast from StringType` case so
`Char -> Double` isn't dragged in), and `Inline.idr`'s `allLiteralArgs`
overflow guard -- which reuses `safeConst` -- has to keep working (its
concern is fixed-width *integer* wraparound under gcc
`-Werror=overflow`, which a `Double` chain can't trigger, so dropping
`Db` from its `hasUnfoldableConst` is fine). Investigated 2026-09-10,
not yet done -- see `git log` for the fusion commit this was split off
from.

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
  implementations (`idris2rc2_cast_Char_to_string`, the shortest-form
  `Double -> String` formatter and GMP-exact `String -> Double` parser,
  `String -> Integer/Int*` parsers).
- `rc2/tests/Test7CastMatrix.idr` -- header comment documents the
  `atoll`-vs-`atoi` String-source divergence and three unrelated
  upstream RefC-runtime bugs found while investigating this area
  (`idris2_cast_Double_to_Int8` missing entirely, `idris2_cast_String_to_*`
  defined with a capital S while RefC's own compiler emits calls to
  the lowercase form, `idris2_negate_Double` typo'd as
  `idris2_nagate_Double`) -- none of these are rc2 bugs.
- `rc2/tests/Test17ConstFold.idr` -- regression tests confirming all
  three directions above stay unfolded.
- `rc2/src/Compiler/RC2/Inline.idr` -- `allLiteralArgs`/
  `hasUnfoldableConst` reuse `safeConst`; any change to `Db`'s
  treatment there has to keep the gcc `-Werror=overflow` guard working.

## Verification methodology (if reopening this)

1. **`Char -> String`**: first confirm whether upstream's `castString`
   `Ch` case (or `stripQuotes`) has been fixed to handle multi-character
   escapes correctly. If so, port the fix's reasoning, don't just widen
   `foldableOp` -- re-derive from `Show Char`'s current escaping rules
   whether every codepoint now round-trips correctly through
   `show`+un-escape, not just ASCII printables.
2. **`Double -> String`**: this can't move without first revisiting
   `safeConst`'s `Db` exclusion project-wide (it excludes `Db` from
   every PrimFn, not just Cast) -- that's a bigger, separate decision,
   scoped in the "`Double` arithmetic ..." section above. If ever taken
   up, verify `idris2rc2_cast_Double_to_string`'s shortest-form output
   against the host's own `Show Double` output across a boundary-value
   sweep (0.0, negative zero, very large/small magnitudes, values on
   either side of the plain/scientific threshold, `|x| < 1` where the
   leading-zero convention differs) before trusting any single example.
   The arithmetic/comparison/`Sqrt`/`Floor`/`Ceiling`/`int -> Double`
   subset needs no such sweep (IEEE-exact both sides); the
   transcendentals do (host `libm` vs target `libm`).
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
