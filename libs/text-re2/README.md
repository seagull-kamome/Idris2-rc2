# text-re2

`Text.Regex.RE2` -- Idris2 bindings to Google's [RE2](https://github.com/google/re2)
regular-expression engine, through a small `extern "C"` shim
(`support/c/re2_util.cpp`) built into its own shared object
`libidris2rc2re2`.

This started life as a module inside `rc2base`. It's a separate package
because RE2 is C++ and its `pkg-config --libs` expands to dozens of
abseil `-l` flags, so the shim has to be compiled with `g++` and linked
into its own `.so` (a `%foreign` `lib` field can only name one bare
`-l<name>`). Keeping it here means `rc2base` builds with a plain C
toolchain (`gcc`/`ar`) and only consumers who actually
`import Text.Regex.RE2` need `re2`/`pkg-config`/`g++`. See
`doc/regex.md` for the full rationale.

## Build & test

Building the shim needs **`re2`, `pkg-config`, and `g++`** on `PATH`
(e.g. `nix-shell -p re2 pkg-config gcc gnumake`). Without them
`prebuild`'s `re2_util.o` step fails outright (`<re2/re2.h>` not found).

Default Chez backend, plain type-check:
```sh
idris2 --build text-re2.ipkg
```

Against `idris2-rc-cg`'s own `rc2` backend (`libs/text-re2` lives inside
`idris2-rc-cg`, so no cross-repo `env.sh` juggling). Install into the
*same* `install/` prefix rc2 itself uses -- idris2 searches its own
installation prefix by default, so no separate package-path setup is
needed, and no `IDRIS2_PREFIX` export either -- `env.sh`'s self-built
`idris2` already defaults to this repo's own `install/` on its own
(run `idris2 --prefix` to see it):
```sh
cd idris2-rc-cg            # repo root
source ./env.sh
(cd libs/text-re2 && idris2 --install text-re2.ipkg)

INSTALLED_LIB="$(pwd)/install/idris2-0.8.0/text-re2-0.1.0/lib"
./rc2/build/exec/idris2-rc2 --cg rc2 -p text-re2 -o TestRE2 libs/text-re2/tests/TestRE2.idr

export LD_LIBRARY_PATH="$INSTALLED_LIB:$LD_LIBRARY_PATH"
./build/exec/TestRE2
```
No `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed here at all -- `-p text-re2`
alone is enough, `Compiler.RC2.CC`'s own `depPkgLibDirs` already adds
`-I`/`-L` for it automatically (see "Native library install location"
below). `libidris2rc2re2.so` is a genuine shared object though (unlike
`rc2base`'s static `.a`), so it still needs finding at *runtime*, not
just link time -- that's the only reason `LD_LIBRARY_PATH` is still
needed here at all; `INSTALLED_LIB` alone is enough for it, no
`support/rc2` needed too (that directory has no `.so` of its own).

`tests/verify.sh` does exactly this end to end (clean C rebuild, Chez
type-check, install into a throwaway prefix, `--cg rc2` build of
`tests/TestRE2.idr`, run, diff against `tests/TestRE2.expected`).

## Native library install location

Same convention as `rc2base` -- see `libs/rc2base/README.md`'s "Native
library install location" section. `idris2 --install` copies only
`.ttc`/`.ttm`/`.ipkg`; this package's `postinstall` hook (`make -C
support/c install`) is what puts `libidris2rc2re2.so` and
`re2_util.h` into
`<IDRIS2_PREFIX>/idris2-<ver>/text-re2-0.1.0/lib/`. `Compiler.RC2.CC`'s
own `depPkgLibDirs` finds that `lib/` automatically for every
depended-upon package (`-p text-re2` or an `.ipkg` `depends` entry is
enough) -- no manual `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed for
*that*. Being a genuine shared object rather than a static archive,
`libidris2rc2re2.so` itself still needs `LD_LIBRARY_PATH` pointed at
that same `lib/` at *runtime* (see the "Build & test" example above)
-- `depPkgLibDirs` only ever affects the compiler's own `-I`/`-L`, never
the dynamic linker's own runtime search path.

## API

```idris2
import Text.Regex.RE2

Just re <- compile "([a-z]+)=([0-9]+)"
  | Nothing => ...             -- invalid pattern

fullMatch re "foo=42"                       -- True
partialMatch re "xx foo=42 yy"              -- True
find re "foo=42 bar=7"                      -- Just [Just "foo=42", Just "foo", Just "42"]
replaceFirst  re "[\\1:\\2]" "foo=42 bar=7" -- "[foo:42] bar=7"
globalReplace re "[\\1:\\2]" "foo=42 bar=7" -- "[foo:42] [bar:7]"
```

`compile` once, reuse the result across as many
`fullMatch`/`partialMatch`/`find`/`replaceFirst`/`globalReplace` calls
as needed. `matches`/`findFirst` are one-off shorthands that recompile
the pattern every call.

`find`'s per-group `Nothing` distinguishes "this group didn't
participate in the match" (the losing side of a `(a)|(b)` alternation)
from `Just ""` (matched, matched nothing).

Two things worth knowing, both in `doc/regex.md` in full: RE2 writes a
one-time abseil-logging line (and invalid-pattern parse errors) to
stderr unconditionally; and `rewrite` is an Idris2 reserved word, so
the replacement-string parameter is named `replacement` -- naming it
`rewrite` silently breaks parsing of the rest of the module.
