# `Text.Regex.RE2`: bindings to Google's RE2

## Motivation

None of this project's own string tools (`Data.String`'s split/break/
trim, `Data.Text`) do regular-expression matching, and hand-rolling one
in Idris2 would be slow and easy to get subtly wrong (backtracking
blowup, Unicode edge cases). RE2 is a mature, linear-time C++ regex
engine already packaged in nixpkgs -- `Text.Regex.RE2` wraps its C++
API through a small `extern "C"` shim.

## Why a separate shared object, unlike this package's other bindings

RE2's own API is C++, not C, and `pkg-config --libs re2` pulls in
dozens of `-l` flags for its abseil dependencies -- not something
`Compiler.RC2.Emit`'s `linkLibName` (one `%foreign` `lib` field, one
`-l` name) could ever name directly. `support/c/re2_util.cpp` is
compiled with `g++` and linked into its own `libidris2rc2re2.so`,
with re2/abseil linked into *that* .so (see `support/c/Makefile`'s own
comment) -- so the `%foreign` declarations in this module only ever
need to say `libidris2rc2re2`, one name, same as every other binding
here.

The build embeds an `-Wl,-rpath` pointing at this build's own
`pkg-config`-resolved `libre2`/abseil location, so a consumer doesn't
need `LD_LIBRARY_PATH` set up to run the result -- at the cost of
tying the built `.so` to this machine's own nix store paths. Fine for
this project's own dev-environment scope; not something to rely on for
a redistributable binary.

## Build requirements

Building this module needs `re2`, `pkg-config`, and a C++ compiler
(`g++`) available -- add `re2 pkg-config` to whatever `nix-shell -p
...` invocation builds `rc2base` (see the top-level `run-idris2-rc-cg`
skill's own build commands). Without `pkg-config`/`re2` on `PATH`,
`re2_util.o`'s own compile step fails outright (`<re2/re2.h>` not
found) -- this module is not optional/gracefully-degrading within
`rc2base`'s single `.ipkg`.

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
