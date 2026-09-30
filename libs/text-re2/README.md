# text-re2

`Text.Regex.RE2` -- Idris2 bindings to Google's [RE2](https://github.com/google/re2)
regular-expression engine, through a small `extern "C"` shim
(`support/c/idris2rc2_text_re2_re2_util.cpp`) built into its own shared
object `libidris2rc2re2`.

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
`prebuild`'s `idris2rc2_text_re2_re2_util.o` step fails outright
(`<re2/re2.h>` not found).

`text-re2.ipkg` also `depends = rc2base` (`Text.Regex.RE2` imports
`Data.String.RC2` for `byteLength`/`unsafeStringFromBytes` -- see
"NUL bytes" below), so `rc2base` must already be installed into the
same prefix before building or installing this package (see
`libs/rc2base/README.md`'s own "Build & test" section).

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
(cd libs/rc2base && idris2 --install rc2base.ipkg)   # if not already installed
(cd libs/text-re2 && idris2 --install text-re2.ipkg)

INSTALLED_LIB="$(pwd)/install/idris2-0.8.0/text-re2-0.1.0/lib"
./rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base -p text-re2 -o TestRE2 libs/text-re2/tests/TestRE2.idr

export LD_LIBRARY_PATH="$INSTALLED_LIB:$LD_LIBRARY_PATH"
./build/exec/TestRE2
```
Both `-p rc2base` and `-p text-re2` are needed on this `idris2-rc2`
command line because `TestRE2.idr` is compiled directly, not through
an `.ipkg`: `-p` only adds the named package's own `lib/`, it doesn't
walk that package's `.ipkg` `depends` transitively, so `-p text-re2`
alone would miss `rc2base`'s `libidris2rc2base.a` (needed for
`byteLength`/`unsafeStringFromBytes`) even though `text-re2.ipkg`
itself depends on `rc2base`. A consumer with its own `.ipkg` that has
`depends = text-re2` doesn't need to also write `depends = rc2base`
there -- `.ipkg` `depends` resolution is transitive, unlike `-p`. No
`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed otherwise -- `Compiler.RC2.CC`'s
own `depPkgLibDirs` already adds `-I`/`-L` for each named package
automatically (see "Native library install location" below).
`libidris2rc2re2.so` is a genuine shared object though (unlike
`rc2base`'s static `.a`), so it still needs finding at *runtime*, not
just link time -- that's the only reason `LD_LIBRARY_PATH` is still
needed here at all; `INSTALLED_LIB` alone is enough for it, no
`support/rc2` needed too (that directory has no `.so` of its own).

`tests/verify.sh` does most of this end to end (clean C rebuild, Chez
type-check, install into the same shared `install/` prefix rc2 itself
uses (not a separate throwaway one), `--cg rc2` build of
`tests/TestRE2.idr` with both `-p rc2base -p text-re2`, run, diff
against `tests/TestRE2.expected`) -- it does not install `rc2base`
itself, though, it assumes `rc2base` is already installed into that
shared prefix (see `libs/rc2base/tests/verify.sh`).

## Native library install location

Same convention as `rc2base` -- see `libs/rc2base/README.md`'s "Native
library install location" section. `idris2 --install` copies only
`.ttc`/`.ttm`/`.ipkg`; this package's `postinstall` hook (`make -C
support/c install`) is what puts `libidris2rc2re2.so` and
`idris2rc2_text_re2_re2_util.h` into
`<IDRIS2_PREFIX>/idris2-<ver>/text-re2-0.1.0/lib/`. `Compiler.RC2.CC`'s
own `depPkgLibDirs` finds that `lib/` automatically for every
depended-upon package (`-p text-re2` on the command line, or an
`.ipkg` `depends` entry, is enough on its own) -- no manual
`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed for *that*. The two aren't
equivalent for `rc2base`, though: `-p` only adds the package named on
the command line, not that package's own transitive `.ipkg` depends,
while `.ipkg` `depends` resolution does walk transitively -- so `-p
text-re2` alone (compiling a source file directly) misses `rc2base`'s
`lib/`, but a consumer `.ipkg` with `depends = text-re2` gets it for
free. That's why the "Build & test" example above passes `-p rc2base
-p text-re2` together. Being a genuine shared object rather than a
static archive,
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

Three things worth knowing, all in `doc/regex.md` in full: RE2 writes a
one-time abseil-logging line (and invalid-pattern parse errors) to
stderr unconditionally; `rewrite` is an Idris2 reserved word, so the
replacement-string parameter is named `replacement` -- naming it
`rewrite` silently breaks parsing of the rest of the module; and the
shim's own C functions are named `idris2rc2_re2_*`, not
`idris2rc2_regex_*`, because a program that linked both this module
and `rc2base`'s own `Text.Regex.POSIX` binding under the
`idris2rc2_regex_*` name got the wrong one's functions and crashed.

## NUL bytes

Every string crosses into the shim as a pointer plus an explicit byte
length (`Data.String.RC2.byteLength`), never a NUL-terminated C
string, and every string result (a captured group, `replaceFirst`'s or
`globalReplace`'s output) comes back as a pointer plus a separate
length accessor, turned into a `String` with
`Data.String.RC2.unsafeStringFromBytes`. So a NUL byte in the subject,
the pattern, a captured group, or a replacement result is ordinary
data, not a terminator -- RE2's `.` matches a NUL byte.
`tests/TestRE2.idr` checks this directly.
