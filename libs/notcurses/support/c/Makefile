# notcurses-core is a plain C library -- unlike libs/text-re2's shim
# (C++ RE2, dozens of abseil -l flags), this needs only `gcc`/`pkg-config`
# and one small object linked straight against libnotcurses-core. See
# ../../doc/notcurses.md for why a shim exists at all despite that.

CC ?= cc

comma := ,

NC_CFLAGS  := $(shell pkg-config --cflags notcurses-core 2>/dev/null)
NC_LIBS    := $(shell pkg-config --libs notcurses-core 2>/dev/null || echo -lnotcurses-core)
NC_LIBDIRS := $(patsubst -L%,%,$(filter -L%,$(NC_LIBS)))
NC_RPATH   := $(addprefix -Wl$(comma)-rpath$(comma),$(NC_LIBDIRS))

# Must match notcurses.ipkg's own `version` field.
NOTCURSES_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/notcurses-$(NOTCURSES_VERSION)/lib

all: libidris2rc2notcurses.so

# Embeds notcurses-core's own store path as an rpath so a consumer
# doesn't need LD_LIBRARY_PATH set up for it (same reasoning as
# libs/text-re2/support/c/Makefile) -- ties the .so to this machine's
# nix store, acceptable for this project's dev-environment scope.
nc_util.o: nc_util.c nc_util.h
	# gnu11 + _XOPEN_SOURCE=700: notcurses.h's own inline functions use
	# strdup/wcwidth/wcswidth, which need glibc's feature-test macros
	# enabled -- strict c11 hides them and fails with implicit-
	# declaration errors.
	$(CC) -fPIC -Wall -Wextra -O2 -D_XOPEN_SOURCE=700 $(NC_CFLAGS) -std=gnu11 -c nc_util.c -o nc_util.o

libidris2rc2notcurses.so: nc_util.o
	$(CC) -shared -fPIC -o $@ nc_util.o $(NC_LIBS) $(NC_RPATH)

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2notcurses.so nc_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2notcurses.so nc_util.o
