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

## Caveats

All inherent to POSIX `regexec`, not this binding:

- **NUL-terminated input.** `regexec` takes a `char *`, so a `\0` in
  the subject string ends the search there. glibc's `REG_STARTEND`
  extension would allow byte-exact / binary matching against an
  explicit range; not wired up here (would want a `Buffer`-based entry
  point, and it's a GNU extension, not POSIX).
- **Byte offsets.** `matchSpans` and the substring slicing in `match`
  are byte-indexed. `Data.String.strSubstr` is also byte-indexed under
  `--cg rc2`/`--cg refc` (so they line up), but codepoint-indexed under
  `--cg chez` -- non-ASCII input would misalign there.
- **Leftmost-longest** ("POSIX") match, not leftmost-first (PCRE-style).
- **No named groups.** No global-match primitive -- `matchAll` iterates
  `regexec`, advancing one byte past an empty match so it terminates.
- Backreferences (`\1`) work in BRE and, as a glibc extension, in ERE.
  `()` group in ERE, `\(\)` in BRE.

## Verified

`tests/TestRegexPOSIX.idr` (in `tests/verify.sh`), under `--cg rc2`:
ERE and BRE compile, `matches`/`match` with groups (participating,
absent via `(a)|(b)`, empty via `x(a*)y`), `ignoreCase`, `matchAll`,
`replaceFirst`/`replaceAll` with `\1`/`\2`, a BRE `\1` backreference,
and a `Left` for an invalid pattern.
