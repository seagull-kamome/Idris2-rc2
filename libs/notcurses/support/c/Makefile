# notcurses-core is a plain C library -- unlike libs/text-re2's shim
# (C++ RE2, dozens of abseil -l flags), this needs only `gcc`/`pkg-config`
# and one small object archived straight into a static lib, the same
# way libs/rc2base/support/c/Makefile does. See ../../doc/notcurses.md
# for why a shim exists at all despite that.

CC ?= cc
AR ?= ar

NC_CFLAGS := $(shell pkg-config --cflags notcurses-core 2>/dev/null)

# Must match notcurses.ipkg's own `version` field.
NOTCURSES_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/notcurses-$(NOTCURSES_VERSION)/lib

all: libidris2rc2notcurses.a

# A static archive, not a shared object: -lnotcurses-core itself is
# still resolved dynamically at the *consumer's* own final link (every
# %foreign declaration bound directly to libnotcurses-core already
# pulls that in, see src/System/Notcurses.idr) -- this archive only
# ever needs to compile nc_util.o, never link anything itself.
nc_util.o: nc_util.c nc_util.h
	# gnu11 + _XOPEN_SOURCE=700: notcurses.h's own inline functions use
	# strdup/wcwidth/wcswidth, which need glibc's feature-test macros
	# enabled -- strict c11 hides them and fails with implicit-
	# declaration errors.
	$(CC) -fPIC -Wall -Wextra -O2 -D_XOPEN_SOURCE=700 $(NC_CFLAGS) -std=gnu11 -c nc_util.c -o nc_util.o

libidris2rc2notcurses.a: nc_util.o
	$(AR) rcs $@ nc_util.o

install: all
	mkdir -p $(LIBDIR)
	# Was a shared object before this package switched to a static
	# archive -- a stale .so left over from an earlier install would
	# otherwise win over the .a at a consumer's link step (the linker
	# prefers a .so when both are present on its search path).
	rm -f $(LIBDIR)/libidris2rc2notcurses.so
	cp libidris2rc2notcurses.a nc_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2notcurses.a nc_util.o
