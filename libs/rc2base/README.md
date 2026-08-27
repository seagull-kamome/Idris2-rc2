# rc2base

A `Data.Text` type wrapping a UTF-8-derived codepoint buffer, backed by
a small C shim (`support/c/text_util.c`, built into
`support/c/libidris2text.a` via the package's own `prebuild` hook).
`idris2 --install` doesn't know about that `.a`/its header on its own
-- see the "Native library install location" section below for how
(and where) they end up in an installed copy of this package.

## Build & test

Default Chez backend, plain type-check:
```sh
idris2 --build rc2base.ipkg
```

To build `tests/TestText.idr` against the library (rather than just
type-checking `rc2base.ipkg` itself), install the library into a
local prefix first -- the default Idris2 package location lives in a
read-only nix store here, same reasoning as `idris2-curl/AGENT.md`'s
own "Build & test" section:
```sh
export IDRIS2_PREFIX="$(pwd)/.local-install"
idris2 --install rc2base.ipkg
```

Against `idris2-rc-cg`'s own `rc2` backend (this repo's own
sibling directory -- `libs/rc2base` lives inside `idris2-rc-cg`
itself, so no separate checkout/`env.sh` sourcing across repos is
needed, unlike an external consumer such as `idris2-curl`):
```sh
cd idris2-rc-cg   # repo root
source ./env.sh
export IDRIS2_PREFIX="$(pwd)/libs/rc2base/.local-install"
(cd libs/rc2base && idris2 --install rc2base.ipkg)

INSTALLED_LIB="$(pwd)/libs/rc2base/.local-install/idris2-0.8.0/rc2base-0.1.0/lib"
export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$(pwd)/libs/rc2base/.local-install/idris2-0.8.0"
export IDRIS2_CFLAGS="-I$INSTALLED_LIB -I$(pwd)/install/idris2-0.8.0/support"
export IDRIS2_LDFLAGS="-L$INSTALLED_LIB"
./rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base -o TestText libs/rc2base/tests/TestText.idr

export LD_LIBRARY_PATH="$(pwd)/install/idris2-0.8.0/support/rc2:$LD_LIBRARY_PATH"
./build/exec/TestText
```
`IDRIS2_CFLAGS=-I...` puts `text_util.h` (installed alongside the
compiled library -- see below) and rc2's own runtime headers
(`rc2/datatypes.h`/`rc2/memory.h`/`rc2/utf8.h`, which `text_util.h`
itself includes) on the include path. `IDRIS2_LDFLAGS=-L...` puts the
installed library on the *linker's* search path -- required
separately, see the caveat below. Note this points at the *installed*
`lib/` directory, not `support/c/` in the source tree -- see the next
section for why that's the correct target now.

## Native library install location

Idris2's own packaging convention (`idris2-src/docs/source/reference/
packages.rst`, "Support file install directories") treats two
subdirectories of a package's install root specially: `lib` (compiled
libraries) and `data`. `idris2 --install` creates the install root
itself and copies `.ttc`/`.ttm`/the `.ipkg` file there, but it has no
idea this package also has a C shim to ship -- it never creates or
populates `lib` on its own. This package's `postinstall` hook
(`rc2base.ipkg`, running `support/c/postinstall.sh`) does that:
after `idris2 --install`, `libidris2text.a` and `text_util.h` land in
`<IDRIS2_PREFIX>/idris2-<idris2 version>/rc2base-0.1.0/lib/`.

One caveat worth being explicit about: this `lib` convention is
**picked up automatically only by the Chez/Racket backends**, which
`dlopen` a dependency's `.so`/`.dylib` out of its `lib/` directory at
build time with zero configuration (`Compiler.Common`'s
`locate`/`copyLib`, via `Core.Directory.findLibraryFile`). rc2, like
upstream RefC, links `%foreign` libraries statically via plain `-L`/
`-l` flags, and neither one ever adds a dependency's own `lib/`
directory to that search path automatically (confirmed against
`idris2-src/src/Idris/Driver.idr`'s `lib_dirs`, which is populated only
from `IDRIS2_LIBS`, the toolchain's own install dir, and the current
working directory). So for rc2 specifically, installing to `lib/` is
still necessary groundwork (a genuinely portable, self-contained
installed copy of this package, not scattered across a source
checkout) but not sufficient on its own -- a consumer still has to
point `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` (or `IDRIS2_LIBS`) at that `lib/`
directory themselves, same as the example above does.

## Caveat: the `%foreign` lib field must be a bare `-l` name, not a path

rc2 auto-derives a `-l<name>` linker flag from every `%foreign`
declaration's own lib field (`Compiler.RC2.Emit`'s `linkLibName`), but
only when that field's value literally starts with `"lib"` -- it
strips that prefix and passes the rest straight to `-l`. It is *not* a
file path: a field like `"libs/rc2base/support/c/libidris2text.a"`
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
that's what `IDRIS2_LDFLAGS=-L$INSTALLED_LIB` (see the "Build & test"
example above) is for. Plain upstream Chez/`idris2 --cg refc` builds
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

### `System.Random.Xoshiro128PlusPlus`

A pure-Idris port of xoshiro128++ (Blackman & Vigna, 2018, public
domain) -- the 32-bit-output, 128-bit-state member of the
xoshiro/xoroshiro family. Reference C implementations:
[xoshiro128plusplus.c](https://prng.di.unimi.it/xoshiro128plusplus.c)
(the `next` step) and
[splitmix64.c](https://prng.di.unimi.it/splitmix64.c) (`seed`'s own
expansion of a single `Bits64` into the four words of initial state).
Written because upstream contrib's `System.Random` is entirely
`%foreign`-backed with only `scheme:`/`javascript:` implementations --
unusable on refc/rc2 (or any C backend) at all, see `TODO.md`'s
"Upstream stdlib `%foreign` declarations with no C/RefC backend at
all" -- and this module is not a patch onto that primitive, just an
independent replacement with its own API.

```idris2
record Gen where
  constructor MkGen
  s0, s1, s2, s3 : Bits32
```
The generator's full 128 bits of state, deliberately kept as four
`Bits32` fields rather than packed into two `Bits64` fields, even
though that looks like the more "natural" 128-bit layout. `Bits32` (and
every other <=32-bit scalar) is one of rc2's own `alwaysUnboxed` types
(`Compiler.RC2.Types.alwaysUnboxed`): a tagged pointer, never a real
heap allocation, with `dup`/`drop` already a no-op against it and every
arithmetic op pure pointer-tag manipulation. `Bits64` is not in that
set -- it's a real heap-boxed value needing a fresh allocation and
refcount traffic on every new value `next` produces. Packing to 2x64
would shrink `Gen`'s own constructor from 4 slots to 2, but at the cost
of boxing a fresh `Bits64` per repacked half on every single step, plus
the pack/unpack shifting needed to get back at the algorithm's own
32-bit halves -- a net loss, not a win, under rc2's value-representation
model, even though it would look like the "obvious" choice under a
representation model (like GHC's) where a boxed 64-bit word isn't any
more expensive than a boxed 32-bit one.

```idris2
seed       : Bits64 -> Gen
next       : Gen -> (Bits32, Gen)
nextDouble : Gen -> (Double, Gen)
```
All pure. `seed` expands one caller-chosen `Bits64` into a full `Gen`
via two splitmix64 steps (Vigna, public domain; used here only to mix
a single seed into four well-distributed `Bits32` words, not part of
xoshiro128++ itself). `next` is one xoshiro128++ step: the algorithm's
own 32-bit output plus the successor state, threaded through explicitly
since there is no mutable cell here to hide it in. `nextDouble` maps
that same step's output onto a uniform `Double` in `[0,1)` at the
generator's native 32-bit precision (`output / 2^32`) -- not the full
53-bit `Double` mantissa's worth of randomness some other generators
provide.

```idris2
nextBits32   : HasIO io => IORef Gen -> io Bits32
nextDoubleIO : HasIO io => IORef Gen -> io Double
newSeeded    : HasIO io => io (IORef Gen)
```
Convenience wrappers around the pure core above, for the common case of
threading a generator through a sequence of `IO` actions instead of
carrying the successor state by hand. `nextBits32`/`nextDoubleIO` each
do a plain read-`next`-write cycle against the given `IORef`.
Deliberately just `IORef Gen`, not an opaque handle bundling a `Mutex`:
that read-then-write is two separate operations, not one atomic step,
so it is not safe for multiple threads to share the same `IORef`
without their own guard -- a caller needing that wraps it in a `Mutex`
(`System.Concurrency`) themselves, same as any other shared mutable
state; a fresh `IORef Gen` per thread needs no such guard at all.

This also rules out the seemingly simpler alternative of a single
top-level global generator (`unsafePerformIO`-backed, no explicit
`IORef` threading needed at call sites): neither rc2 nor upstream RefC
ever memoizes a 0-argument top-level definition (a CAF) the way, say,
GHC does -- both re-run its body, a fresh call, every single time it's
referenced (confirmed against `Compiler.RC2.Emit`'s and upstream
`Compiler.RefC.RefC`'s own handling of the `nargs == 0` case). A global
`unsafePerformIO (newIORef (seed ...))`-shaped CAF would therefore
silently hand back a *new*, independently-seeded `IORef` on every
reference, never a single shared one -- so state cannot be hidden
behind a memoized top-level singleton on this backend the way it might
on Chez/JS, and the caller must instead create one `IORef Gen` itself
and thread it explicitly, which is exactly what these wrappers ask for.

`newSeeded` is a convenience constructor building one such `IORef` from
a non-fixed default seed (the monotonic clock mixed with the current
process id via `System.Clock`/`getPID`) -- not cryptographically
secure, just a reasonable "don't hand me the same sequence every run"
default. Use `newIORef . seed` directly instead for a reproducible,
caller-chosen seed.
