# idris2-Text

A `Data.Text` type wrapping a UTF-8-derived codepoint buffer, backed by
a small C shim (`support/c/text_util.c`, built into
`support/c/libidris2text.a` via the package's own `prebuild` hook).

## Build & test

Default Chez backend, plain type-check:
```sh
idris2 --build idris2-Text.ipkg
```

To build `tests/TestText.idr` against the library (rather than just
type-checking `idris2-Text.ipkg` itself), install the library into a
local prefix first -- the default Idris2 package location lives in a
read-only nix store here, same reasoning as `idris2-curl/AGENT.md`'s
own "Build & test" section:
```sh
export IDRIS2_PREFIX="$(pwd)/.local-install"
idris2 --install idris2-Text.ipkg
```

Against `idris2-rc-cg`'s own `rc2` backend (this repo's own
sibling directory -- `libs/idris2-Text` lives inside `idris2-rc-cg`
itself, so no separate checkout/`env.sh` sourcing across repos is
needed, unlike an external consumer such as `idris2-curl`):
```sh
cd idris2-rc-cg   # repo root
source ./env.sh
export IDRIS2_PREFIX="$(pwd)/libs/idris2-Text/.local-install"
(cd libs/idris2-Text && idris2 --install idris2-Text.ipkg)

export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$(pwd)/libs/idris2-Text/.local-install/idris2-0.8.0"
export IDRIS2_CFLAGS="-Ilibs/idris2-Text/support/c"
export IDRIS2_LDFLAGS="-Llibs/idris2-Text/support/c"
./rc2/build/exec/idris2-rc2 --cg rc2 -p idris2-Text -o TestText libs/idris2-Text/tests/TestText.idr

export LD_LIBRARY_PATH="$(pwd)/install/idris2-0.8.0/support/rc2:$LD_LIBRARY_PATH"
./build/exec/TestText
```
`IDRIS2_CFLAGS=-I...` puts `text_util.h` on the include path (the
generated C references it via the `%foreign` declarations' own header
field). `IDRIS2_LDFLAGS=-L...` puts `support/c/` on the *linker's*
search path -- required separately, see the caveat below.

## Caveat: the `%foreign` lib field must be a bare `-l` name, not a path

rc2 auto-derives a `-l<name>` linker flag from every `%foreign`
declaration's own lib field (`Compiler.RC2.Emit`'s `linkLibName`), but
only when that field's value literally starts with `"lib"` -- it
strips that prefix and passes the rest straight to `-l`. It is *not* a
file path: a field like `"libs/idris2-Text/support/c/libidris2text.a"`
does not start with `"lib"` in the way `linkLibName` expects (or,
worse, if it does incidentally match the prefix check, produces a
broken `-l` flag with a slash in it) -- either way `-l<lib>` silently
never reaches the linker and every symbol from that library comes back
`undefined reference`, with rc2's own compile step reporting success
right up until the final link.

The correct form -- what `src/Data/Text.idr` uses -- is the bare
library name, `"lib"`-prefixed, no path, no extension:
```idris2
%foreign "C:idris2rc2_String_to_TextBuffer,libidris2text,text_util.h"
prim__String_to_TextBuffer : String -> PrimIO AnyPtr
```
This becomes `-lidris2text`. The linker still needs to be told *where*
`libidris2text.a` lives, since it isn't on any default search path --
that's what `IDRIS2_LDFLAGS=-Lsupport/c` (or the repo-root-relative
form above) is for. Plain upstream Chez/`idris2 --cg refc` builds
don't derive `-l` flags automatically at all and don't need any of
this rc2-specific `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` plumbing in the
first place (Chez's own FFI dynamically loads `%foreign`'s lib field
by name at runtime instead).

## API

```idris2
data Text : Nat -> Type
```
A Unicode codepoint sequence, length-indexed by its own codepoint
count `n` (not byte length).

```idris2
fromString : (s : String) -> (n : Nat ** Text n)
toString   : Text n -> String
length     : Text n -> Nat
index      : {n : Nat} -> Text n -> Fin n -> Char
(++)       : Text n -> Text m -> Text (n + m)
```
All pure -- no `IO` needed for construction, conversion, indexing, or
concatenation. Deallocation is automatic: every `Text` wraps a
`GCAnyPtr` whose native buffer is freed by a GC finalizer
(`onCollectAny`) once the value becomes unreachable, so there is no
explicit `free` to call.

```idris2
0 lengthCorrect : {n:Nat} -> (xs:Text n) -> length xs = n
```
A deliberate, erased (`0`-quantity, zero runtime cost) axiom, not a
mechanically checked proof -- `length` re-reads `n` through an opaque
C FFI call every time, which Idris's proof checker can't see through.
It holds by construction instead: every `Text` value is reached only
through this module's own smart constructors, each of which sets the
underlying C buffer's `len` field to exactly `n`, and no operation
here ever mutates a buffer's `len` afterward.

`toString`'s implementation is worth calling out: `text_util.c`'s
`idris2rc2_TextBuffer_to_string` builds a fully-formed, correctly
tagged `IDRIS2RC2_String` directly in C (via rc2's own
`idris2rc2_mkEmptyString`) and returns it as a Boxed `Value*`. On the
Idris side, the `%foreign` declaration's return type is a local,
never-constructed opaque marker (`RawTextValue`), not `String` --
declaring it as `String` would make rc2's own FFI marshaller wrap the
already-Boxed value a *second* time via `idris2rc2_mkString`. An
unrecognized return type instead maps to rc2's `CFUser` case, whose
packing/unpacking is the identity, so the value flows through
untouched; `believe_me` then tells the type checker what's already
true at runtime. This avoids an extra copy through an intermediate
`char *` buffer.
