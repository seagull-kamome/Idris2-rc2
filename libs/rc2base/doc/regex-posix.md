# `Text.Regex.POSIX`: bindings to libc `<regex.h>`

## Motivation

rc2base already had an RE2 binding, but RE2 is C++ and drags in
`g++`/`pkg-config`/abseil at build time -- so it lives in its own
package now (`text-re2`). POSIX regular expressions
(`regcomp`/`regexec`/`regfree`/`regerror`) are in libc: every build
already links them, no toolchain beyond `gcc`. `Text.Regex.POSIX` is a
thin binding for the common case where a POSIX regex is enough and the
extra dependency isn't worth it.

## Architecture

- `support/c/posix_regex.c` -- a small shim. Idris can't manage a
  platform-sized `regex_t` or a `regmatch_t[]` array directly, so the
  shim `malloc`s the `regex_t`, runs `regcomp`/`regexec`, and stashes
  the match offsets in a **thread-local** growable buffer (grown to
  `re_nsub + 1` slots per exec). Thread-local, not one static buffer
  like `event_util.c`'s epoll cache, so `match` can stay pure *and*
  safe to call from more than one thread. Compile errors are captured
  into a thread-local string (`regerror` needs the `regex_t`, so the
  message is taken before `regfree`).
- `Text.Regex.POSIX` -- `Flags`/`ere`/`bre`, an opaque `Regex`
  (`GCPtr`, `regfree`+`free` on collection), and the match/replace API.
  `compile` is `IO`; `groupCount`/`match`/`matches`/`matchAll`/
  `replaceFirst`/`replaceAll` are pure (`unsafePerformIO` over a
  referentially-transparent match against a compiled pattern -- same
  choice the old RE2 module made).

## API

```idris
ere, bre : Flags                                    -- ERE (default) / BRE; also `newline`, `ignoreCase`
compile     : {default ere flags : Flags} -> String -> IO (Either String Regex)
groupCount  : Regex -> Int
matches     : Regex -> String -> Bool
match       : Regex -> String -> Maybe (List (Maybe String))          -- [whole, group1, ...]
matchSpans  : Regex -> String -> Maybe (List (Maybe (Int, Int)))      -- same, as byte offsets
matchAll    : Regex -> String -> List (List (Maybe String))           -- non-overlapping, left to right
replaceFirst, replaceAll : Regex -> (replacement : String) -> String -> String
```

Case-insensitive: `compile {flags = { ignoreCase := True } ere} pat`.
`newline` sets `REG_NEWLINE` (`.` and negated bracket expressions stop
at `\n`; `^`/`$` also match next to one).

A `Nothing` element in a `match` result is a group that didn't
participate in the match (the losing branch of a `|`, an unmatched
`(...)?`), kept distinct from `Just ""` (a group that matched, and
matched the empty string).

`replaceFirst`/`replaceAll` -- POSIX defines no replacement syntax, so
this module's is: `\0`..`\9` insert that group's text (empty if the
group didn't participate), `\\` is a literal backslash, any other `\x`
becomes `x`.

## Locale: `.` and character classes are codepoint-wise under UTF-8

`regexec`'s pattern semantics are locale-dependent. In the `"C"` locale
its engine is byte-wise: `.` matches one byte, `[[:alpha:]]` /
`[[:digit:]]` / case-insensitive matching are ASCII-only, `.{4}` counts
bytes. With a UTF-8 `LC_CTYPE`, glibc switches to its multibyte path --
`.` matches a whole codepoint, character classes use the
wide-character predicates.

rc2's runtime does `setlocale(LC_ALL, "")` at startup
(`idris2rc2_rtInit`, see `rc2/doc/runtime-lifecycle.md`), so this
binding gets the multibyte behaviour **whenever the process runs under
a UTF-8 locale** -- which also means the *charset must be
UTF-8-compatible*: a subject matched under `ja_JP.eucJP` or
`de_DE.iso88591` comes back as bytes rc2's `String` layer then
misreads. `C.UTF-8` / `en_US.UTF-8` / ... are fine; plain `C` falls
back to byte-wise. `matchSpans` offsets are byte offsets in every
locale (see below), so `unsafeStringByteSlice` slicing is unaffected.

## Caveats

Inherent to POSIX `regexec`, not this binding:

- **NUL-terminated input.** `regexec` takes a `char *`, so a `\0` in
  the subject string ends the search there. glibc's `REG_STARTEND`
  extension would allow byte-exact / binary matching against an
  explicit range; not wired up here (would want a `Buffer`-based entry
  point, and it's a GNU extension, not POSIX).
- **Byte offsets.** `regexec` reports byte offsets, and `matchSpans`
  passes them straight through (its `(Int, Int)` pairs are byte
  offsets, not codepoint indices). `match`/`matchAll`/`replace*` cut
  those spans out with `Data.String.RC2.unsafeStringByteSlice` -- a
  real byte slice -- and bound their scan loops with byte length, so
  they are UTF-8-correct: a multi-byte character before or inside a
  group no longer shifts the result. (rc2's own `strSubstr`/`strIndex`
  are codepoint-indexed, which is why the plain `Data.String` ones
  can't be used against `regexec` offsets.)
- **Leftmost-longest** ("POSIX") match, not leftmost-first (PCRE-style).
- **No named groups.** No global-match primitive -- `matchAll` iterates
  `regexec`, advancing one whole codepoint past an empty match so it
  terminates without splitting a character.
- Backreferences (`\1`) work in BRE and, as a glibc extension, in ERE.
  `()` group in ERE, `\(\)` in BRE.

## Verified

`tests/TestRegexPOSIX.idr` (in `tests/verify.sh`, run under
`LC_ALL=C.UTF-8`), under `--cg rc2`: ERE and BRE compile,
`matches`/`match` with groups (participating, absent via `(a)|(b)`,
empty via `x(a*)y`), `ignoreCase`, `matchAll`,
`replaceFirst`/`replaceAll` with `\1`/`\2`, a BRE `\1` backreference,
a `Left` for an invalid pattern, multi-byte UTF-8 input
(`match "café=αβ"` groups land on the right bytes, `replaceAll` over
Greek-letter context copies the non-matched runs correctly), and
codepoint-wise pattern semantics under a UTF-8 locale (`^.$` matches
`"é"`, `^[[:alpha:]]+$` matches `"café"`, `^.{4}$` matches `"café"`
but not `"caféz"`).
