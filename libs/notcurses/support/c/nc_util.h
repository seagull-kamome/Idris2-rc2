#ifndef IDRIS2RC2_NC_UTIL_H
#define IDRIS2RC2_NC_UTIL_H

/* Every %foreign declaration touching notcurses in src/System/
 * Notcurses.idr names *this* header, never <notcurses/notcurses.h>
 * directly -- one consolidated header instead of splitting off a
 * second, narrower one just for the few declarations that don't
 * strictly need the full thing.
 *
 * This does NOT, on its own, fix the `-D_XOPEN_SOURCE=700
 * -D_DEFAULT_SOURCE` requirement on every consumer's own
 * IDRIS2_CFLAGS (see doc/notcurses.md's "A real gotcha" section) --
 * tried defining `_XOPEN_SOURCE` right here, first thing in this
 * file, before this same #include; still failed the exact same way.
 * rc2's generated C always `#include <idris2rc2_runtime.h>` first,
 * unconditionally, ahead of every %foreign header including this one
 * -- and that alone already drags in glibc's <features.h> (via its
 * own buffer.h -> stdint.h) before this file is ever reached, which
 * decides glibc's feature-test state for the whole translation unit
 * right then. A `#define` anywhere after that point, in any header,
 * has no effect; only a compiler command-line `-D` (which glibc sees
 * as if it were written before the first line of the file) is early
 * enough. So the consumer-side IDRIS2_CFLAGS requirement stays,
 * regardless of which header any of this is declared against. */
#include <notcurses/notcurses.h>
#include <stdint.h>

/* Everything notcurses itself exports as a real, linkable symbol (either
 * always -- anything marked `API` in notcurses.h -- or, built against
 * libnotcurses-ffi, anything that's `static inline` in the header, e.g.
 * notcurses_render/ncplane_putstr/notcurses_get_blocking) is bound
 * directly from Idris via %foreign against "libnotcurses-core" /
 * "libnotcurses-ffi" -- see src/System/Notcurses.idr. This shim exists
 * only for the handful of things %foreign genuinely cannot do itself:
 * building a `notcurses_options`/`ncplane_options` value to pass by
 * pointer (no per-field struct construction from Idris), and reading
 * back the multi-field `ncinput` an input call writes into (no portable
 * field-offset knowledge on the Idris side). See doc/notcurses.md.
 */

/* `struct notcurses`/`struct ncplane` come from notcurses.h itself
 * (included above) -- no need to forward-declare them separately here. */

/* `notcurses_core_init(opts, fp)` wrapper: builds the options struct
 * internally and fixes fp to NULL (stdout) -- exposing the raw FILE*
 * parameter to Idris isn't worth the complexity for this package's
 * scope. Returns NULL on failure, same as the real function. */
struct notcurses *idris2rc2_nc_init(int loglevel, unsigned margin_t, unsigned margin_r, unsigned margin_b, unsigned margin_l);

/* `ncplane_create(parent, nopts)` wrapper: builds the options struct
 * internally (flags/userptr/resizecb/margin_b/margin_r all left at 0/
 * NULL -- none of those are exposed by this package; see
 * doc/notcurses.md). `name` may be NULL. */
struct ncplane *idris2rc2_ncplane_create(struct ncplane *parent, int y, int x, unsigned rows, unsigned cols, const char *name);

/* `notcurses_get_blocking`/`_nblock`'s `ncinput*` out-param is cached
 * here (one shared buffer, overwritten by the next call -- same
 * read-before-you-call-again contract as libs/text-re2's find()/
 * group() pair) and exposed through flat getters below. Returns the
 * event's `id` field directly, exactly like the real functions. */
uint32_t idris2rc2_nc_get_blocking(struct notcurses *nc);
uint32_t idris2rc2_nc_get_nonblock(struct notcurses *nc);

int idris2rc2_nc_last_input_y(void);
int idris2rc2_nc_last_input_x(void);
unsigned idris2rc2_nc_last_input_modifiers(void);
/* One of the ncintype_e values (NCTYPE_UNKNOWN/PRESS/REPEAT/RELEASE). */
int idris2rc2_nc_last_input_evtype(void);
/* Into the same cache as the fields above -- rc2's %foreign String
 * marshaling copies at the call site (see libs/text-re2/support/c/
 * re2_util.h's identical reasoning), so this is safe to hand back
 * directly. Never NULL (empty string when the event has no UTF-8
 * representation, e.g. a bare special key). */
const char *idris2rc2_nc_last_input_utf8(void);

/* NCKEY_* special-key codes are `preterunicode(w)`-derived (a private
 * macro adding a version-specific base offset), not plain integer
 * literals -- unlike NCKEY_MOD and NCSTYLE (plain small ints, safe to
 * copy straight into Idris), these have to come from the real macro
 * expansion to stay correct across a notcurses version bump. Covers
 * the keys this package's examples use; add more here (not by
 * guessing the offset on the Idris side) if a future wrapper needs
 * one that isn't here yet.
 *
 * `static inline`, not declared here + defined in nc_util.c: each is a
 * pure one-line return of a compile-time constant, no shared state
 * unlike the input-cache getters above, so there's no correctness
 * reason to force an out-of-line call through libidris2rc2notcurses.so
 * -- defining them here lets a call site that includes this header
 * (which %foreign's own header field arranges) fold each straight down
 * to its constant, the same way notcurses.h's own `static inline`
 * helpers already do. */
static inline uint32_t idris2rc2_nckey_invalid(void) { return NCKEY_INVALID; }
static inline uint32_t idris2rc2_nckey_resize(void) { return NCKEY_RESIZE; }
static inline uint32_t idris2rc2_nckey_up(void) { return NCKEY_UP; }
static inline uint32_t idris2rc2_nckey_down(void) { return NCKEY_DOWN; }
static inline uint32_t idris2rc2_nckey_left(void) { return NCKEY_LEFT; }
static inline uint32_t idris2rc2_nckey_right(void) { return NCKEY_RIGHT; }
static inline uint32_t idris2rc2_nckey_ins(void) { return NCKEY_INS; }
static inline uint32_t idris2rc2_nckey_del(void) { return NCKEY_DEL; }
static inline uint32_t idris2rc2_nckey_backspace(void) { return NCKEY_BACKSPACE; }
static inline uint32_t idris2rc2_nckey_pgup(void) { return NCKEY_PGUP; }
static inline uint32_t idris2rc2_nckey_pgdown(void) { return NCKEY_PGDOWN; }
static inline uint32_t idris2rc2_nckey_home(void) { return NCKEY_HOME; }
static inline uint32_t idris2rc2_nckey_end(void) { return NCKEY_END; }
static inline uint32_t idris2rc2_nckey_enter(void) { return NCKEY_ENTER; }
static inline uint32_t idris2rc2_nckey_f01(void) { return NCKEY_F01; }
static inline uint32_t idris2rc2_nckey_f02(void) { return NCKEY_F02; }
static inline uint32_t idris2rc2_nckey_f03(void) { return NCKEY_F03; }
static inline uint32_t idris2rc2_nckey_f04(void) { return NCKEY_F04; }

#endif
