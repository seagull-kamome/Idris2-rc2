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

### `System.Random.Xoroshiro128PlusPlus` / `System.Random.Xoroshiro64StarStar`

Two thin FFI wrappers around C ports of the real xoroshiro128++ and
xoroshiro64** algorithms (Blackman & Vigna, 2019, public domain) --
respectively the 64-bit-output/128-bit-state and 32-bit-output/64-bit-
state members of the xoshiro/xoroshiro family. Despite the similar
naming, neither is a scaled variant of the other. Reference C
implementations:
[xoroshiro128plusplus.c](https://prng.di.unimi.it/xoroshiro128plusplus.c)/
[xoroshiro64starstar.c](https://prng.di.unimi.it/xoroshiro64starstar.c),
mechanically renamed into `support/c/xoroshiro128plusplus.c`/
`xoroshiro64starstar.c` (C symbol prefixes
`idris2rc2_System_Random128_*`/`idris2rc2_System_Random_*`
respectively -- note the un-"128"-suffixed prefix belongs to the
64-bit-state module, not the 128-bit one, despite looking like it
should be the other way round). Written because upstream contrib's
`System.Random` is entirely `%foreign`-backed with only
`scheme:`/`javascript:` implementations -- unusable on refc/rc2 (or any
C backend) at all, see `TODO.md`'s "Upstream stdlib `%foreign`
declarations with no C/RefC backend at all" -- and neither module is a
patch onto that primitive, just an independent replacement with its own
API. Kept in C (rather than ported to pure Idris) mainly so the
reference algorithms' own `jump()`/`long_jump()`/`jump_ce()`/`jump_n()`
machinery stays available below with no from-scratch
F2X-polynomial-arithmetic port needed.

Both modules share the same API shape:

```idris2
export
data IOGen  -- opaque; wraps a Buffer holding the raw state

newIOGen   : HasIO io => Bits64 -> io (Maybe IOGen)
copyIOGen  : HasIO io => IOGen -> io (Maybe IOGen)
next       : HasIO io => IOGen -> io Bits32   -- Bits64 for Xoroshiro128PlusPlus
nextDouble : HasIO io => IOGen -> io Double
newSeeded  : HasIO io => io (Maybe IOGen)

jump     : HasIO io => IOGen -> io ()
longJump : HasIO io => IOGen -> io ()
jumpCE   : HasIO io => IOGen -> (c : Bits64) -> (e : Bits32) -> io ()
jumpN    : HasIO io => IOGen -> (n : Bits64) -> io ()   -- two Bits64 words for Xoroshiro128PlusPlus
```
plus a `setSystemSeed`/`nextIO`/`jumpIO`/`longJumpIO`/`jumpCEIO`/
`jumpNIO` family operating on a single global generator (below).

`IOGen` wraps a `Buffer` holding the algorithm's raw state (8 bytes for
Xoroshiro64StarStar, 16 for Xoroshiro128PlusPlus), mutated in place by
`next`/`jump`*, rather than threaded by hand as a pure value or hidden
behind an `IORef`: `next` calls straight into the reference C algorithm
via the `"C"` tag, and `Compiler.RC2.EmitUtil`'s `extractValue CLangC
CFBuffer` unwraps a `Buffer` argument to a flat pointer straight at its
data (no size header in the way), so the C side can treat it exactly as
the reference algorithm's own `uint32_t s[2]`/`uint64_t s[2]`, reading
consecutive words as native-endian -- which only agrees with the
buffer's own little-endian-by-construction layout (`Data.Buffer.
setBits32`/`setBits64`) on realistic little-endian targets (x86/x86_64/
ARM in their default mode); not a coincidence this project relies on
elsewhere, but not a real risk in practice either. `newIOGen`/
`copyIOGen`/`newSeeded` return `Maybe`, `Nothing` only on buffer
allocation failure -- a possibility a `Buffer`-backed design has that a
plain `newIORef` never did. `copyIOGen` clones a generator's current
state into a second, independent `IOGen` (a fresh `Buffer`, `Data.
Buffer.copyData`-populated) -- the two then produce identical output
until one is mutated, since each holds its own state from that point
on.

`newIOGen` expands a caller-chosen `Bits64` seed into the full state
via one (`Xoroshiro64StarStar`, 64-bit state) or two
(`Xoroshiro128PlusPlus`, 128-bit state) splitmix64 (Vigna, public
domain) steps, to avoid handing the algorithm a poorly-diffused or
all-zero state -- exactly the seeding method the reference
implementation's own header comment suggests. `nextDouble` maps a
step's output onto a uniform `Double` in `[0,1)` at the generator's own
native precision (`output / 2^32` or `output / 2^64`) -- not the full
53-bit `Double` mantissa's worth of randomness some other generators
provide. `newSeeded` is a convenience constructor seeded from the
monotonic clock mixed with the current process id (`System.Clock`/
`getPID`) -- not cryptographically secure, just a reasonable "don't
hand me the same sequence every run" default; use `newIOGen` directly
for a reproducible, caller-chosen seed.

`jump`/`longJump`/`jumpCE`/`jumpN` wrap the reference algorithm's own
jump-ahead machinery, advancing a generator's state as if by `2^k` (or
`c * 2^e`, or an arbitrary caller-given distance) calls to `next`
without actually stepping through that many -- useful for handing out
non-overlapping subsequences to independent parallel computations.
`jumpN`'s distance is one `Bits64` word for `Xoroshiro64StarStar`
(whose whole state is 64 bits) and two for `Xoroshiro128PlusPlus` (128
bits) -- simpler than the reference algorithm's own general
`POLY_WORDS`-word `jump[]` array, sized for generators with larger
state than either of these.

Each module also offers a separate, single global generator
(`setSystemSeed`/`nextIO`/`jumpIO`/`longJumpIO`/`jumpCEIO`/`jumpNIO`)
held entirely in C-side static state (each `support/c/*.c`'s own
`system_seed[...]`) -- not thread-safe (no locking around the shared
mutable state, unlike even the "caller must guard their own `IOGen`"
contract the per-instance API above leaves to callers), offered purely
as a quick, no-instance-to-carry-around convenience akin to C's own
`rand()`/`srand()`. Prefer `newIOGen`/`next` for anything concurrent or
reproducible.

The single-global-generator design is also the answer to a seemingly
simpler alternative: a top-level `unsafePerformIO`-backed `IOGen`,
needing no explicit handle threading at call sites. Neither rc2 nor
upstream RefC ever memoizes a 0-argument top-level definition (a CAF)
the way, say, GHC does -- both re-run its body, a fresh call, every
single time it's referenced (confirmed against `Compiler.RC2.Emit`'s
and upstream `Compiler.RefC.RefC`'s own handling of the `nargs == 0`
case). A top-level `unsafePerformIO (newIOGen ...)`-shaped CAF would
therefore silently hand back a *new*, independently-seeded (and
independently `Buffer`-allocated) `IOGen` on every reference, never a
single shared one -- so a memoized top-level singleton isn't available
on this backend the way it might be on Chez/JS. The `*IO` functions
above sidestep this by living in C-side static state rather than behind
an Idris-side CAF, which is exactly why they're implemented in C rather
than as a thin Idris wrapper over a top-level `IOGen`.

An earlier version of `Xoroshiro128PlusPlus` -- under the same module
name but implementing a different algorithm, xoshiro128++ (32-bit
output over 4x `Bits32` state) -- was a from-scratch, pure-Idris port
instead of a C wrapper, with a pure `Gen` record (`seed`/`next`/
`nextDouble`) threaded by hand plus `IORef`-based convenience wrappers
(`nextBits32`/`nextDoubleIO`/`newSeeded`). That implementation has been
replaced outright by the real xoroshiro128++ ported above -- a
different algorithm despite the shared "128"/"++" naming, not merely a
rename.

### `Data.Buffer.RC2`

Patches the five upstream `Data.Buffer` primitives that carry only a
`"scheme:..."` `%foreign` tag and are therefore unusable on refc/rc2
(or any C backend) at all -- see `TODO.md`'s "Upstream stdlib
`%foreign` declarations with no C/RefC backend at all" entry. Unlike
the `System.Random` modules above (independent replacements built from
scratch -- upstream's own primitives there have no C-reachable
implementation whatsoever to patch onto at all), `rc2/support/rc2/
buffer.h` already had every one of these under a different name:
`setInt16`/`getInt32`/`setInt32`
(upstream's own already-working `"RefC:..."` tags matching that
runtime's symbol names verbatim) show the same runtime was always
meant to cover the rest of `Data.Buffer` too. This module just wires
the remaining five up via `%foreign_impl` (the same mechanism
`System.Concurrency.RC2` uses):

```
prim__setInt8  -> setBufferUInt8
prim__getInt8  -> getBufferByte
prim__getInt16 -> getBufferInt16LE
prim__setInt64 -> setBufferInt64LE
prim__getInt64 -> getBufferInt64LE
```

`getBufferByte` is worth calling out: that's also the C symbol
upstream's own already-working `"RefC:getBufferByte"` tag targets from
`prim__getByte` -- a *different* primitive, with a plain `Int` return
rather than `Int8`. Reused here as-is rather than given a fresh name:
the same C macro produces the correct result either way, since
sign-reinterpretation happens at the *caller's* return-holding local,
not inside the macro (`Compiler.RC2.EmitUtil`'s `cTypeOfCFType`
declares that local at the FFI declaration's own target width --
`int8_t` for `prim__getInt8`, plain `int64_t` for `prim__getByte` --
so the same unsigned-built macro result narrows/sign-extends correctly
under either return type). Renaming it would have silently broken the
other, already-shipped `prim__getByte` patch instead of adding
anything. This module's own test (`tests/TestBufferRC2.idr`)
round-trips negative and boundary values through all five to confirm
the sign handling is actually correct, not just assumed from reading
the macro.

Tagged `"RC2:"`, not `"RefC:"`, unlike upstream's own three
already-working entries above: those are upstream's pre-existing
declarations that happen to name real rc2 runtime symbols, not
something this module adds. Adding a *new* `"RefC:"`-tagged entry
ourselves would make a real `idris2 --cg refc` build believe upstream
itself supports these -- it doesn't, there's no such symbol in its own
runtime -- failing confusingly at final link instead of not compiling
at all. `"RC2:"` is rc2-exclusive (`EmitUtil.idr`'s own `ffiTags`) and
silently ignored by any other backend, same as `System.Concurrency.RC2`'s
own patches.

Surfaced a real rc2 compiler bug the first time this module was
written: `Compiler.RC2.Emit`'s `emitGenericForeignWrapper` treated
every non-`"RefC"` foreign tag (including the newly-introduced
`"RC2"`) as generic C for the purpose of unwrapping a `CFBuffer`
argument -- but `EmitUtil.idr`'s `extractValue`'s two `CFBuffer` cases
are not interchangeable: `CLangRefC` passes the whole
size-header-carrying `IDRIS2RC2_Buffer` allocation `buffer.h`'s own
macros expect, while `CLangC` skips past that header for generic
byte-buffer functions with no notion of it. This had been silently
correct for `System.Concurrency.RC2`'s own earlier patches purely
because none of them happen to take a `CFBuffer`-typed argument, and
only became visible once a patch that does (this one) was written.
Fixed by a one-line change treating `"RC2"` the same as `"RefC"` for
this one purpose; verified against rc2's full regression suite
(`rc2/tests/verify.sh`, refc-suite 19/19, smoke+valgrind 82/82) with
no other change. See `KNOWN-BUGS.md`'s own "Retired: ..." entry for
this fix's own writeup.

### `Data.Double.RC2`

Patches upstream `Data.Double`'s `unitRoundoff`/`epsilon`/`nan`/`inf`,
each of which carries only a `"scheme:..."`/`"node:..."` `%foreign`
tag and is therefore unusable on refc/rc2 (or any C backend) at all --
see `TODO.md`'s same "Upstream stdlib `%foreign` declarations..."
entry. Unlike `Data.Buffer.RC2` above (rc2's own runtime already had
every needed primitive under a different name), `rc2/support/rc2/
numeric.h` needed four small new `static inline` functions --
`idris2rc2_unitRoundoff`/`idris2rc2_epsilon`/`idris2rc2_nan`/
`idris2rc2_inf` -- since there was nothing to reuse:

```c
static inline double idris2rc2_unitRoundoff(void) { return DBL_EPSILON / 2.0; }
static inline double idris2rc2_epsilon(void)      { return DBL_EPSILON; }
static inline double idris2rc2_nan(void)          { return NAN; }
static inline double idris2rc2_inf(void)          { return INFINITY; }
```

Values matched against upstream's own Chez definition
(`idris2-src/support/chez/support.ss`), not just assumed:
`blodwen-calcFlonumUnitRoundoff` halves a value repeatedly until
`1.0 + uro == 1.0` first holds -- the classic round-to-nearest-even
boundary, which provably converges to exactly `DBL_EPSILON / 2` for
IEEE 754 binary64 -- and `epsilon` is exactly double that
(`DBL_EPSILON` itself, the smallest value that does *not* leave `1.0`
unchanged when added). This module's own test (`tests/
TestDoubleRC2.idr`) checks those defining properties directly
(`1.0 + unitRoundoff == 1.0`, `1.0 + epsilon != 1.0`,
`epsilon == unitRoundoff * 2`, plus `nan != nan` and
`1.0 / inf == 0.0`) rather than hardcoding a literal comparison.

Each of these is declared upstream as a plain `Double` -- not
`PrimIO Double` -- an arity-0, non-monadic `%foreign` value, a shape
no other rc2/rc2base `%foreign_impl` patch had used before this one.
Confirmed working via a standalone scratch program (compiled and run,
not just read out of the compiler source) before writing this module
for real: like any other arity-0 top-level definition on this
backend, a call to one of these four is re-evaluated fresh at every
reference site rather than memoized as a CAF (neither rc2 nor
upstream RefC ever memoizes a 0-argument top-level definition the way,
say, Chez/GHC do -- see the `System.Random.Xoroshiro128PlusPlus` /
`System.Random.Xoroshiro64StarStar` section above for the same point
made about a *stateful* generator case, where the identical
non-memoization behavior would actually have been a bug). Harmless here
specifically because all four are pure, side-effect-free constants --
re-evaluating `idris2rc2_inf()` a second
time returns the same `INFINITY` either way.

Tagged `"RC2:"`, not `"RefC:"`, for the same reason as
`Data.Buffer.RC2` above: these symbol names are new, rc2-only
additions to rc2's own runtime, not something a real `idris2 --cg refc`
build's own runtime also happens to provide.
