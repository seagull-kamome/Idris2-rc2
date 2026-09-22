#ifndef IDRIS2RC2_NOTCURSES_NC_UTIL_H
#define IDRIS2RC2_NOTCURSES_NC_UTIL_H

/* Every %foreign declaration touching notcurses in src/System/
 * Notcurses.idr names *this* header. It never #includes
 * <notcurses/notcurses.h> itself -- only <notcurses/nckeys.h> (just
 * NCKEY_* macros + stdint/stdbool, confirmed to need no glibc feature-
 * test macros of its own).
 *
 * Reasoning, verified by actually building both ways: notcurses.h
 * defines ~200 `static inline` functions (channel/cell manipulation,
 * notcurses_render, ncplane_putstr, ...), and a handful of them --
 * unrelated to anything this package binds, e.g. nccell_strdup(),
 * ncplane_putwstr_aligned() -- call strdup()/wcwidth()/wcswidth(),
 * which glibc only declares under _XOPEN_SOURCE/_DEFAULT_SOURCE. A
 * `static inline` function's body is parsed and type-checked the
 * moment its header is #included, regardless of whether anything in
 * that translation unit ever calls it -- so #including the whole
 * header here, even though this package only *uses* a small slice of
 * it, dragged every consumer's IDRIS2_CFLAGS into needing
 * `-D_XOPEN_SOURCE=700 -D_DEFAULT_SOURCE` just to satisfy functions
 * nobody was calling. No amount of #define-ing those macros in a
 * header included *after* the real one helps either (rc2's generated
 * C always #includes its own runtime prelude first, which already
 * locks glibc's feature-test state via <stdint.h> -> <features.h>
 * before any %foreign header is ever reached).
 *
 * The fix: never give consumers the real header at all.
 *   - Functions notcurses.h marks `API` (always a real, body-less
 *     declaration, implemented in the library itself, never inline)
 *     are hand-declared directly below, copied verbatim from
 *     notcurses.h's own prototypes -- these were already being bound
 *     by symbol name via %foreign against libnotcurses-core, so this
 *     changes nothing about what's trusted, just where the prototype
 *     text lives.
 *   - Functions that only exist as a `static inline` body in the
 *     vendor header (previously bound against notcurses' separate
 *     "-ffi" build, which exports them as real symbols too -- see
 *     git history / doc/notcurses.md) are now wrapped instead:
 *     `nc_util.c` is the ONLY translation unit that #includes the
 *     real <notcurses/notcurses.h>, confining the strdup/wcwidth/
 *     wcswidth requirement entirely inside this shim's own Makefile
 *     (already compiles with `-D_XOPEN_SOURCE=700`). Bonus: since
 *     idris2rc2_notcurses_nc_util.c calls these through the plain (non-NOTCURSES_FFI)
 *     header, they're inlined straight into idris2rc2_notcurses_nc_util.c's own object
 *     code -- libnotcurses-ffi isn't needed at all anymore, dropping
 *     an entire external dependency (and the "-ffi" build variant
 *     isn't guaranteed to be packaged everywhere the plain library
 *     is).
 */
#include <notcurses/nckeys.h>
#include <stdint.h>

struct notcurses;
struct ncplane;

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
 * `static inline`, not declared here + defined in idris2rc2_notcurses_nc_util.c: each is a
 * pure one-line return of a compile-time constant, no shared state
 * unlike the input-cache getters above, so there's no correctness
 * reason to force an out-of-line call through libidris2rc2notcurses.a
 * -- defining them here lets a call site that includes this header
 * (which %foreign's own header field arranges) fold each straight down
 * to its constant, the same way notcurses.h's own `static inline`
 * helpers already do. nckeys.h alone (included above) is enough for
 * these -- no strdup/wcwidth/wcswidth in sight. */
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

/* -- Always-real (`API`-attributed, never inline) notcurses-core
 * symbols -- hand-declared verbatim from notcurses.h's own
 * prototypes, bound directly by symbol name via %foreign. No body
 * ever exists in the vendor header for these, so there's nothing to
 * confine -- only the declaration text needs to stay in sync with
 * notcurses' own signatures (see doc/notcurses.md's "Keeping this up
 * to date"). */
const char *notcurses_version(void);
int notcurses_stop(struct notcurses *nc);
int ncplane_destroy(struct ncplane *n);
struct ncplane *notcurses_stdplane(struct notcurses *nc);
int ncplane_move_yx(struct ncplane *n, int y, int x);
int ncplane_cursor_move_yx(struct ncplane *n, int y, int x);
void ncplane_erase(struct ncplane *n);
int ncplane_set_fg_rgb8(struct ncplane *n, unsigned r, unsigned g, unsigned b);
int ncplane_set_bg_rgb8(struct ncplane *n, unsigned r, unsigned g, unsigned b);
void ncplane_set_fg_default(struct ncplane *n);
void ncplane_set_bg_default(struct ncplane *n);
int ncplane_set_fg_alpha(struct ncplane *n, int alpha);
int ncplane_set_bg_alpha(struct ncplane *n, int alpha);
void ncplane_set_styles(struct ncplane *n, unsigned stylebits);

/* -- Functions that only exist as `static inline` bodies in the
 * vendor header -- wrapped in idris2rc2_notcurses_nc_util.c, which is the only place that
 * #includes the real <notcurses/notcurses.h>. Bound via %foreign
 * against libidris2rc2notcurses, same as every other shim function
 * above (no more libnotcurses-ffi dependency at all). */
int idris2rc2_nc_render(struct notcurses *nc);
int idris2rc2_ncplane_putstr(struct ncplane *n, const char *gclustarr);
int idris2rc2_ncplane_putstr_yx(struct ncplane *n, int y, int x, const char *gclusters);
int idris2rc2_ncplane_resize_simple(struct ncplane *n, unsigned ylen, unsigned xlen);
unsigned idris2rc2_ncplane_dim_y(const struct ncplane *n);
unsigned idris2rc2_ncplane_dim_x(const struct ncplane *n);
unsigned idris2rc2_ncplane_cursor_y(const struct ncplane *n);
unsigned idris2rc2_ncplane_cursor_x(const struct ncplane *n);
int idris2rc2_ncplane_perimeter_rounded(struct ncplane *n, uint16_t stylemask, uint64_t channels, unsigned ctlword);
int idris2rc2_ncplane_perimeter_double(struct ncplane *n, uint16_t stylemask, uint64_t channels, unsigned ctlword);

#endif
