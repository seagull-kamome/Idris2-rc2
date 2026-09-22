#include "idris2rc2_notcurses_nc_util.h"
#include <notcurses/notcurses.h> /* the ONLY place this shim touches the real header -- see nc_util.h's own comment on why */
#include <string.h>

struct notcurses *idris2rc2_nc_init(int loglevel, unsigned margin_t, unsigned margin_r, unsigned margin_b, unsigned margin_l) {
    notcurses_options opts;
    memset(&opts, 0, sizeof(opts));
    opts.loglevel = (ncloglevel_e) loglevel;
    opts.margin_t = margin_t;
    opts.margin_r = margin_r;
    opts.margin_b = margin_b;
    opts.margin_l = margin_l;
    return notcurses_core_init(&opts, NULL);
}

struct ncplane *idris2rc2_ncplane_create(struct ncplane *parent, int y, int x, unsigned rows, unsigned cols, const char *name) {
    ncplane_options nopts;
    memset(&nopts, 0, sizeof(nopts));
    nopts.y = y;
    nopts.x = x;
    nopts.rows = rows;
    nopts.cols = cols;
    nopts.name = name;
    return ncplane_create(parent, &nopts);
}

/* Not thread-local: notcurses itself is single-UI-thread-only (its own
 * docs disclaim concurrent use of one `struct notcurses*`), so a plain
 * static matches the library's own concurrency contract. */
static ncinput last_input;

uint32_t idris2rc2_nc_get_blocking(struct notcurses *nc) {
    return notcurses_get_blocking(nc, &last_input);
}

uint32_t idris2rc2_nc_get_nonblock(struct notcurses *nc) {
    return notcurses_get_nblock(nc, &last_input);
}

int idris2rc2_nc_last_input_y(void) { return last_input.y; }
int idris2rc2_nc_last_input_x(void) { return last_input.x; }
unsigned idris2rc2_nc_last_input_modifiers(void) { return last_input.modifiers; }
int idris2rc2_nc_last_input_evtype(void) { return (int) last_input.evtype; }
const char *idris2rc2_nc_last_input_utf8(void) { return last_input.utf8; }

/* idris2rc2_nckey_*() are `static inline` in idris2rc2_notcurses_nc_util.h itself -- pure
 * constant getters, no shared-state reason to force them out-of-line
 * here (see that header's own comment on why). */

/* Everything below is `static inline` in <notcurses/notcurses.h>
 * itself (no real exported symbol in the plain "notcurses-core"
 * build) -- each wrapper just forwards straight through, and the
 * compiler inlines the vendor body right here since this is the one
 * translation unit that actually includes the real header. No
 * libnotcurses-ffi dependency needed as a result. */

int idris2rc2_nc_render(struct notcurses *nc) {
    return notcurses_render(nc);
}

int idris2rc2_ncplane_putstr(struct ncplane *n, const char *gclustarr) {
    return ncplane_putstr(n, gclustarr);
}

int idris2rc2_ncplane_putstr_yx(struct ncplane *n, int y, int x, const char *gclusters) {
    return ncplane_putstr_yx(n, y, x, gclusters);
}

int idris2rc2_ncplane_resize_simple(struct ncplane *n, unsigned ylen, unsigned xlen) {
    return ncplane_resize_simple(n, ylen, xlen);
}

unsigned idris2rc2_ncplane_dim_y(const struct ncplane *n) {
    return ncplane_dim_y(n);
}

unsigned idris2rc2_ncplane_dim_x(const struct ncplane *n) {
    return ncplane_dim_x(n);
}

unsigned idris2rc2_ncplane_cursor_y(const struct ncplane *n) {
    return ncplane_cursor_y(n);
}

unsigned idris2rc2_ncplane_cursor_x(const struct ncplane *n) {
    return ncplane_cursor_x(n);
}

int idris2rc2_ncplane_perimeter_rounded(struct ncplane *n, uint16_t stylemask, uint64_t channels, unsigned ctlword) {
    return ncplane_perimeter_rounded(n, stylemask, channels, ctlword);
}

int idris2rc2_ncplane_perimeter_double(struct ncplane *n, uint16_t stylemask, uint64_t channels, unsigned ctlword) {
    return ncplane_perimeter_double(n, stylemask, channels, ctlword);
}
