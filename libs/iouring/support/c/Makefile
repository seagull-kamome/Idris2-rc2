# liburing is a plain C library -- like libs/notcurses/support/c/Makefile,
# this needs only `gcc`/`pkg-config` and one small object archived into a
# static lib. See ../../doc/iouring.md for why a shim exists at all when
# most of liburing's own API is `static inline` and binds directly.

CC ?= cc
AR ?= ar

URING_CFLAGS := $(shell pkg-config --cflags liburing 2>/dev/null)

# Must match iouring.ipkg's own `version` field.
IOURING_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/iouring-$(IOURING_VERSION)/lib

all: libidris2rc2iouring.a

# A static archive, not a shared object: -luring itself is still
# resolved dynamically at the *consumer's* own final link (every
# %foreign declaration naming it as a library -- both this shim's own
# functions and every direct liburing.h binding in
# src/System/IO/Uring.idr -- already pulls it in via
# Compiler.RC2.CC's own auto-collected -l<name> flags) -- this archive
# only ever needs to compile iouring_util.o, never link anything itself.
iouring_util.o: iouring_util.c iouring_util.h
	$(CC) -fPIC -Wall -Wextra -O2 $(URING_CFLAGS) -std=gnu11 -c iouring_util.c -o iouring_util.o

libidris2rc2iouring.a: iouring_util.o
	$(AR) rcs $@ iouring_util.o

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2iouring.a iouring_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2iouring.a iouring_util.o
