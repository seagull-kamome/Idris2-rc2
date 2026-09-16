# `System.Notcurses`

Idris2 bindings to [notcurses](https://notcurses.com/)' core TUI API,
targeting `idris2-rc-cg`'s own `rc2` backend only.

## Why `notcurses-core`, not `notcurses`

`pkg-config` exposes `notcurses-core` (the base library) and
`notcurses` (adds multimedia -- images/video, via ffmpeg). This
package links only against `notcurses-core` -- multimedia support
isn't in scope (see "What's not covered" below), and pulling it in
would drag ffmpeg/libavcodec into every consumer's dependency closure
for no benefit. (A third module, `notcurses-ffi`, exports every
header `static inline` function as a real symbol too -- this package
used to bind some functions directly against it, but no longer does;
see "Why a C shim exists at all" below.)

## Why a C shim exists at all

Only `notcurses.h` functions marked `API` (always a real, body-less,
linkable symbol -- implemented in the library itself, never inline)
bind straight onto notcurses' own real symbols via `%foreign`, the
same way `Data.Integer.GMP` binds directly onto `libgmp` -- their
prototypes are hand-declared in `nc_util.h` (copied verbatim from
notcurses.h's own signatures) rather than pulled from the real vendor
header, for reasons the next section covers. Everything else goes
through `support/c/nc_util.c`:

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
4. **Everything that only exists as a `static inline` body in
   notcurses.h** (`notcurses_render`, `ncplane_putstr`,
   `ncplane_perimeter_rounded`, ~200 of them in total -- channel/cell
   manipulation and more that this package doesn't bind at all) has no
   real, linkable symbol in the plain library. notcurses ships a
   second build of the same library, "`-ffi`" (its own `NOTCURSES_FFI`
   macro turns `static` into `__attribute__((visibility("default")))`
   for the whole header, so `pkg-config --libs notcurses-ffi` exposes
   every one of them as a real exported symbol), and earlier revisions
   of this package bound the ones it needs straight against that.
   **This package no longer does that** -- see "Why `nc_util.h` never
   includes the real header" below for why, and note it as the reason
   `libnotcurses-ffi` is gone from this package's dependencies
   entirely. `idris2rc2_nc_render`/`idris2rc2_ncplane_putstr`/... in
   `nc_util.c` wrap each one instead, forwarding straight through to
   the plain header's own inline definition (which the compiler
   inlines right there, in `nc_util.c`'s own object code).

## Why the `NCKEY_*` getters are `static inline` in the header

`idris2rc2_nc_last_input_y`/`_x`/`_modifiers`/`_evtype`/`_utf8` and
`idris2rc2_nc_get_blocking`/`_get_nonblock` are declared in
`nc_util.h` and *defined* in `nc_util.c`, forcing a real out-of-line
call through `libidris2rc2notcurses.a` -- necessary there, since they
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

## Why `nc_util.h` never includes the real header

An earlier revision of this package had every `%foreign` declaration
name `nc_util.h` as its header, and `nc_util.h` itself
`#include <notcurses/notcurses.h>` in full, reasoning that one
consolidated header was simpler than hand-declaring anything. That
revision required **every consumer** of this package to add
`-D_XOPEN_SOURCE=700 -D_DEFAULT_SOURCE` to its own `IDRIS2_CFLAGS`,
found the hard way: notcurses.h defines ~200 `static inline` functions,
and a handful of them -- entirely unrelated to what this package binds
at all, e.g. `nccell_strdup()` (calls `strdup`),
`ncplane_putwstr_aligned()` (calls `wcswidth`) -- call libc functions
glibc only declares under those feature-test macros. A `static inline`
function's body is parsed and type-checked the instant its header is
`#include`d, regardless of whether that translation unit ever calls
it, so simply including the whole vendor header dragged those two
functions' requirements into every consumer's build even though
nothing in this package ever calls either one.

Tried fixing it with a `#define` ahead of `nc_util.h`'s own
`#include <notcurses/notcurses.h>` first -- **that doesn't work**,
confirmed by actually removing the `IDRIS2_CFLAGS` defines and
rebuilding a consumer program: rc2's generated C always
`#include <idris2rc2_runtime.h>` first, completely unconditionally,
*ahead of every single `%foreign` header*. That alone
(`idris2rc2_runtime.h` -> `buffer.h` -> `<stdint.h>`) already pulls in
glibc's `<features.h>` and locks in its feature-test state for the
whole translation unit before any package header is ever reached -- a
`#define` anywhere after that point has no effect on what glibc
already decided.

**The actual fix: stop giving consumers the real header at all.**
`nc_util.h` now only `#include`s `<notcurses/nckeys.h>` (just
`NCKEY_*` macros + `stdint`/`stdbool`, confirmed to need nothing
glibc-feature-gated) plus hand-declared `extern` prototypes for the
`API`-marked functions this package binds directly. `nc_util.c` is the
*only* translation unit that still `#include`s the real
`<notcurses/notcurses.h>` -- confining the strdup/wcwidth/wcswidth
requirement entirely inside this shim's own Makefile (already compiles
with `-D_XOPEN_SOURCE=700`, since it needs the full struct layouts for
`notcurses_options`/`ncplane_options`/`ncinput` regardless). Every
function that used to be bound straight against `libnotcurses-ffi` is
now wrapped here too (`idris2rc2_nc_render`, `idris2rc2_ncplane_putstr`,
...), which as a side effect drops the `libnotcurses-ffi` dependency
entirely -- calling a `static inline` vendor function from `nc_util.c`
just inlines its body straight into this shim's own object code, no
`-ffi` build variant needed.

The trade-off: the `API`-marked prototypes hand-declared in
`nc_util.h` are this package's own copy of notcurses' signatures, not
pulled from the real header -- see "Keeping this up to date" below for
what that means when notcurses' API moves.

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

Two independent things can drift out of sync with a future notcurses
version, and they fail differently:

- **A hand-declared `API` prototype in `nc_util.h`** (e.g.
  `ncplane_set_fg_rgb8`'s signature) going stale is *silent* at this
  package's own build -- C doesn't check declaration consistency
  across translation units, so a mismatch only surfaces as a strange
  runtime bug or ABI mismatch in a *consumer's* program. If notcurses'
  changelog for a version bump mentions a signature change to any
  function in `nc_util.h`'s "always-real" block, update the
  hand-copied declaration there to match, verbatim, from the real
  `notcurses.h`.
- **A function moving between "always real" (`API`) and
  `static inline`-only** is *loud* at `nc_util.c`'s own build --
  wrapping a now-`API` function through `nc_util.c` still compiles
  fine (nothing stops calling a real symbol from a shim), but a
  function that moved the other way (was `API`, is now
  `static inline`-only) will fail to link when `nc_util.h`'s hand-
  declared `extern` prototype can't find a real symbol at
  `libnotcurses-core` link time -- move its declaration out of
  `nc_util.h`'s "always-real" block and into a `nc_util.c` wrapper
  instead (same shape as `idris2rc2_nc_render` and friends), updating
  `System.Notcurses.idr`'s corresponding `%foreign` declaration to
  point at `libidris2rc2notcurses`/`idris2rc2_*` instead of
  `libnotcurses-core`/the raw name.
