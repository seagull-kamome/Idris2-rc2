# `System.Notcurses`

Idris2 bindings to [notcurses](https://notcurses.com/)' core TUI API,
targeting `idris2-rc-cg`'s own `rc2` backend only.

## Why `notcurses-core`, not `notcurses`

`pkg-config` exposes three relevant modules: `notcurses-core` (the base
library), `notcurses` (adds multimedia -- images/video, via ffmpeg),
and `notcurses-ffi` (see below). This package links only against
`notcurses-core` -- multimedia support isn't in scope (see "What's not
covered" below), and pulling it in would drag ffmpeg/libavcodec into
every consumer's dependency closure for no benefit.

## Why a C shim exists at all

Most of this binding calls straight onto notcurses' own real symbols
via `%foreign`, the same way `Data.Integer.GMP` binds directly onto
`libgmp` -- no shim needed. Two library names show up in
`src/System/Notcurses.idr`'s own `%foreign` declarations:

- `libnotcurses-core`: every function notcurses.h marks `API` --
  always a real, linkable symbol.
- `libnotcurses-ffi`: notcurses ships a second build of the *same*
  library where every header `static inline` function (there are
  ~200 -- channel/cell manipulation, `notcurses_render`,
  `ncplane_putstr`, `notcurses_get_blocking`, `ncplane_perimeter_*`,
  ...) is *also* compiled in as a real exported symbol (its own
  `NOTCURSES_FFI` build macro turns `static` into
  `__attribute__((visibility("default")))` for the whole header).
  `pkg-config --libs notcurses-ffi` names it; `nm -D` confirms exactly
  which functions ended up real per notcurses version (see "Keeping
  this up to date" below).

That covers everything with a plain scalar/pointer signature. What's
left, and what `support/c/nc_util.c` exists for:

1. **`notcurses_options`/`ncplane_options`** are passed *by pointer*,
   but %foreign has no way to construct a struct value field-by-field
   from Idris. `idris2rc2_nc_init`/`idris2rc2_ncplane_create` build one
   on the C side and forward to the real `notcurses_core_init`/
   `ncplane_create`.
2. **`ncinput`** (a multi-field struct an input call writes *into*) has
   the same problem in reverse -- no portable way to read arbitrary
   struct fields back from Idris without knowing byte offsets.
   `idris2rc2_nc_get_blocking`/`_get_nonblock` cache the struct in a
   file-scope static and expose flat getters, the same
   read-before-the-next-call contract `libs/text-re2`'s own
   `find()`/`group()` pair already uses for RE2's capture groups.
3. **`NCKEY_*` special-key codes** are `preterunicode(w)`-derived (a
   private macro adding a version-tagged base offset -- currently
   `1115000`), not plain integers -- unlike `NCKEY_MOD_*`/`NCSTYLE_*`
   (plain small ints, hardcoded straight into
   `System.Notcurses.NCKeyMod`/`NCStyle`), these need the real macro
   expansion to stay correct across a notcurses version bump.
   `idris2rc2_nckey_*()` in `nc_util.h` are the accessors -- see the
   next section for why they're `static inline` there rather than
   declared-in-header-defined-in-`.c` like the rest of the shim.

## Why the `NCKEY_*` getters are `static inline` in the header

`idris2rc2_nc_last_input_y`/`_x`/`_modifiers`/`_evtype`/`_utf8` and
`idris2rc2_nc_get_blocking`/`_get_nonblock` are declared in
`nc_util.h` and *defined* in `nc_util.c`, forcing a real out-of-line
call through `libidris2rc2notcurses.so` -- necessary there, since they
share one file-scope `static ncinput last_input` cache and a header-
`static inline` copy would duplicate that cache once per translation
unit a consuming program's generated C happens to split into,
silently breaking the "read every field before the next call"
contract.

The `NCKEY_*` getters have no such hazard -- each is a pure one-line
return of a compile-time constant, so they're defined directly in
`nc_util.h` as `static inline`, letting a call site (which %foreign's
own header field already arranges to `#include` this file) fold the
call down to the constant outright, exactly like notcurses.h's own
internal `static inline` helpers already do for each other.

## A real gotcha: `-D_XOPEN_SOURCE=700 -D_DEFAULT_SOURCE` is required

**Any program that imports `System.Notcurses` must add
`-D_XOPEN_SOURCE=700 -D_DEFAULT_SOURCE` to `IDRIS2_CFLAGS`** (alongside
the usual `-I`/`-L` for this package's installed `lib/` -- see
README.md). Found the hard way: notcurses.h's own `static inline`
functions call `strdup`/`wcwidth`/`wcswidth`, which glibc only
declares under those feature-test macros -- and rc2's own C compile
step (`Compiler.RC2.CC.compileCObjectFile`) always passes `-Werror`
with no `-std=` override, which promotes glibc's
`-Wimplicit-function-declaration` warning for each of them into a hard
build failure.

Every `%foreign` declaration in `System.Notcurses` names `nc_util.h`
as its header (never `<notcurses/notcurses.h>` directly) -- one
consolidated header, and it's also the header `nc_util.c`'s own
out-of-line definitions compile against, so it seemed like the natural
place to fix this once and for all with a `#define` ahead of its own
`#include <notcurses/notcurses.h>`. **Tried exactly that -- it doesn't
work**, confirmed by actually removing the `IDRIS2_CFLAGS` defines and
rebuilding a consumer program: rc2's generated C always
`#include <idris2rc2_runtime.h>` first, completely unconditionally,
*ahead of every single `%foreign` header* including `nc_util.h`. That
alone (`idris2rc2_runtime.h` -> `buffer.h` -> `<stdint.h>`) already
pulls in glibc's `<features.h>` and locks in its feature-test state
(auto-enabling `_DEFAULT_SOURCE`, but *not* `_XOPEN_SOURCE` --
`wcwidth`/`wcswidth` need the latter specifically) for the whole
translation unit before `nc_util.h` is ever reached. A `#define`
anywhere after that point, in any header this package controls, has
no effect on what glibc already decided -- confirmed by the attempt
literally reproducing the exact same `-Wimplicit-function-declaration`
failure regardless. A compiler-*command-line* `-D` is conceptually
seen before the first line of the file is even read, which is the only
reason it works -- so it has to come from the consumer's own build
(there's no per-package "extra CFLAGS for my dependents" hook in this
rc2 backend today for an `.ipkg` to inject it automatically). This is
independent of which header anything here is declared against; it's
purely about `idris2rc2_runtime.h` always winning the race.

## What's not covered (Tier 2 -- deliberately deferred)

Everything below would need real design/implementation work this
package doesn't attempt yet -- noted here rather than silently
omitted:

- **Multimedia** (`ncvisual`, image/video decode+display) -- needs the
  full `notcurses` module (ffmpeg dependency), out of scope by design
  (see above).
- **Plots/sprixels** (`ncplot`, pixel-graphics blitting) -- not bound.
- **Widgets** (`ncmenu`, `ncreader`, `ncreel`, `ncselector`,
  `nctabbed`, `ncprogbar`, ...) -- each has its own options-struct-by-
  pointer construction need (same shape of problem `idris2rc2_nc_init`/
  `idris2rc2_ncplane_create` solve for the two structs this package
  does cover), multiplied across a dozen-plus widget types. Add a shim
  constructor per widget if a future consumer needs one.
- **`ncdirect`** (the lower-level "direct mode" API, for simple
  scripts that don't want a full alternate-screen UI) -- an entirely
  separate entry point from `notcurses_core_init`, not attempted.
  
- **Raw channel/cell API** (`ncchannel_*`/`nccell_*`, packing fg/bg
  color + alpha + palette-index into one `uint64_t`/`nccell`) -- this
  package's color API (`setFgRgb8`/`setBgRgb8`/`setStyles`/...) only
  covers the plane-level convenience setters, which is enough for
  everything currently in `examples/`. `perimeterRounded`/
  `perimeterDouble` consequently always draw a border in the
  terminal's default color (they take a `channels` value directly, and
  this package always passes `0`) -- exposing per-border-cell color
  needs `ncchannels_set_fg_rgb8`-equivalent packing helpers, not
  implemented here.
- **`notcurses_refresh`** (re-querying live terminal geometry without
  a full render pass) -- real `API` symbol, but its two-`unsigned*`
  out-param signature has the same by-pointer problem as `ncinput`,
  needing its own shim getter pair; skipped since `render` + a plane's
  own `planeDim` already cover this package's examples.
- **Resize callbacks** (`ncplane_options.resizecb`, a function
  pointer) -- exposing an Idris closure as a raw C function pointer
  needs its own trampoline machinery (a fixed C entry point that looks
  up and invokes the right Idris closure, since %foreign can't turn an
  arbitrary closure into a bare function pointer directly);
  `createPlane` always passes `NULL`.
- **Palette (256-color indexed) API** (`ncplane_set_fg_palindex`/
  `_set_bg_palindex`) -- real `API` symbols, trivial to add later, just
  not wired up yet (this package's examples only use direct RGB).

## Keeping this up to date

If a future notcurses version moves a function between "always real"
and "`static inline`" (or removes/renames one), the sign is a link
failure (`undefined reference`) or `-Wimplicit-function-declaration`
naming the exact symbol -- move its `%foreign` declaration's `lib`
field between `libnotcurses-core`/`libnotcurses-ffi` accordingly.
`nm -D <path-to-libnotcurses-ffi.so> | grep ' T '` lists every symbol
currently real in the ffi build, straight from the installed library,
if a fresh check is ever needed rather than trusting this doc's
snapshot.
