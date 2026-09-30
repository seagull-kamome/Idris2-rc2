# `Text.Regex.RE2`: bindings to Google's RE2

## Motivation

None of this project's own string tools (`Data.String`'s split/break/
trim, `Data.Text`) do regular-expression matching, and hand-rolling one
in Idris2 would be slow and easy to get subtly wrong (backtracking
blowup, Unicode edge cases). RE2 is a mature, linear-time C++ regex
engine already packaged in nixpkgs -- `Text.Regex.RE2` wraps its C++
API through a small `extern "C"` shim.

## Why its own package, and its own shared object

RE2's own API is C++, not C, and `pkg-config --libs re2` pulls in
dozens of `-l` flags for its abseil dependencies -- not something
`Compiler.RC2.Emit`'s `linkLibName` (one `%foreign` `lib` field, one
`-l` name) could ever name directly.
`support/c/idris2rc2_text_re2_re2_util.cpp` is
compiled with `g++` and linked into its own `libidris2rc2re2.so`,
with re2/abseil linked into *that* .so (see `support/c/Makefile`'s own
comment) -- so the `%foreign` declarations in `Text.Regex.RE2` only
ever need to say `libidris2rc2re2`, one name.

That per-`.ipkg` `prebuild` hook is also why this is its own package
rather than a module in `rc2base`: everything else in `rc2base` builds
with a plain C toolchain (`gcc`, `ar`), and folding RE2 in would make
`re2`/`pkg-config`/`g++`/abseil a hard build dependency of the whole
library for the one module that needs them. `text-re2` keeps that
dependency to consumers who actually `import Text.Regex.RE2`. The lib
name still reads `libidris2rc2re2` -- kept from when this lived in
`rc2base`, not worth a rename of every `%foreign` line.

The build embeds an `-Wl,-rpath` pointing at this build's own
`pkg-config`-resolved `libre2`/abseil location, so a consumer doesn't
need `LD_LIBRARY_PATH` set up to run the result -- at the cost of
tying the built `.so` to this machine's own nix store paths. Fine for
this project's own dev-environment scope; not something to rely on for
a redistributable binary.

## Build requirements

Building this package needs `re2`, `pkg-config`, and a C++ compiler
(`g++`) available -- add `re2 pkg-config` to whatever `nix-shell -p
...` invocation builds it (see `tests/verify.sh`). Without
`pkg-config`/`re2` on `PATH`, `idris2rc2_text_re2_re2_util.o`'s own
compile step fails outright (`<re2/re2.h>` not found) -- `prebuild`
failing there fails the whole package build.

## String data crosses the shim as a pointer plus a byte length

`text-re2.ipkg` `depends = rc2base`: `Text.Regex.RE2` imports
`Data.String.RC2` for `byteLength` and `unsafeStringFromBytes`. Every
string going into the shim (the pattern given to `compile`, the
subject given to `fullMatch`/`partialMatch`/`find`, the replacement
given to `replaceFirst`/`globalReplace`) is passed as a pointer plus
`byteLength s`, never a NUL-terminated C string; every string coming
back out (a captured group, a replacement result) comes back as a
pointer plus a separate length accessor
(`idris2rc2_re2_group_len`/`idris2rc2_re2_result_len`) and is turned
into a `String` with `unsafeStringFromBytes`. A NUL byte anywhere in
that data -- subject, pattern, captured group, or replacement result
-- is therefore ordinary data, not a terminator, and RE2's own `.`
matches a NUL byte. `tests/TestRE2.idr` checks this
directly: a pattern and a subject each containing `\NUL`, `find`
capturing a group that includes one, and a `globalReplace` whose
subject has one before the first match.

This is also why building this package needs `rc2base` already
installed into the same prefix, on top of `re2`/`pkg-config`/`g++` --
see `README.md`'s "Build & test" section.

## C function names: `idris2rc2_re2_*`, not `idris2rc2_regex_*`

The shim's exported C functions
(`support/c/idris2rc2_text_re2_re2_util.h`) are named `idris2rc2_re2_compile`,
`idris2rc2_re2_find`, and so on -- not `idris2rc2_regex_*`. `rc2base`'s
own POSIX regex binding (`Text.Regex.POSIX`,
`support/c/idris2rc2_rc2base_posix_regex.h`) already uses that
`idris2rc2_regex_*` prefix for its own `idris2rc2_regex_compile`/
`_free`/`_exec`/... functions, and a program linking both `text-re2`
and `rc2base` under one shared `idris2rc2_regex_*` name prefix got
`rc2base`'s functions where it meant RE2's -- observed as a crash.
Naming this module's functions `idris2rc2_re2_*` instead keeps the two
symbol sets disjoint.

## API

```idris2
Just re <- compile "([a-z]+)=([0-9]+)"
  | Nothing => ... -- invalid pattern

fullMatch re "foo=42"      -- True (whole string matches)
partialMatch re "xx foo=42 yy" -- True (matches somewhere)

find re "foo=42 bar=7"
-- Just [Just "foo=42", Just "foo", Just "42"]
-- index 0 is the whole match, 1.. are capturing groups left to right

replaceFirst re "[\\1:\\2]" "foo=42 bar=7"  -- "[foo:42] bar=7"
globalReplace re "[\\1:\\2]" "foo=42 bar=7" -- "[foo:42] [bar:7]"
```

`find`'s per-group `Nothing` distinguishes "this group didn't
participate in the match" (e.g. the losing side of a `(a)|(b)`
alternation) from `Just ""` (the group matched, and matched nothing) --
verified directly: `find` on the pattern `(a)|(b)` against `"b"` gives
`[Just "b", Nothing, Just "b"]`, not `[Just "b", Just "", Just "b"]`.

`matches`/`findFirst` are throwaway one-off shorthands (compile the
pattern every call) -- prefer `compile` once, reused across many
`fullMatch`/`find`/... calls, whenever the same pattern runs more than
once.

## Known limitation: RE2's own logging writes to stderr unconditionally

Every RE2 program using this module prints a one-time `absl::
InitializeLog()` warning to stderr on first use (confirmed harmless --
functionality is unaffected), and an invalid pattern's parse error
(`compile` returning `Nothing`) also logs a message to stderr via
abseil's logging machinery, in addition to `compile`'s own `Nothing`
return. Not suppressed here; a caller that can't tolerate stderr
output from a dependency should filter it externally.

## Bug found while writing this module's own test program: `rewrite` is a reserved word

Naming a function parameter `rewrite` (a natural name for RE2's own
replacement-string argument) silently breaks parsing of **every
declaration after it in the same module**, with the reported error
pointing at some unrelated later declaration rather than at `rewrite`
itself -- confirmed by bisecting this exact file down to a two-line
reproduction (a plain `foo : A -> String -> String -> String; foo a
rewrite b = b` was enough). Root cause: `rewrite` is Idris2's own
`rewrite ... in ...` equality-rewriting expression keyword, not
available as an ordinary identifier -- not a bug in this module or in
rc2 (upstream's own parser reserves the word; not checked here whether
`--cg chez` reproduces the same misleading error-location behavior,
only that the keyword conflict itself is a language-level fact, not an
rc2-specific one). Worth documenting here in detail because the error
message gives no hint whatsoever that the parameter name is the actual
problem -- a future session hitting "Couldn't parse declaration" far
from any apparent syntax error should check for a reserved word
(`rewrite`, `case`, `with`, `let`, ... - anything reads as a keyword,
not just this one) used as a plain identifier before assuming a parser
bug. This module's own parameter is named `replacement` instead.
