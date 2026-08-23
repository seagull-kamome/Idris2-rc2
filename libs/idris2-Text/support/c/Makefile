CC=gcc
CFLAGS+=-fPIC -Wall -Wextra -O2
CFLAGS  += $(addprefix -I,$(subst :, ,$(IDRIS2_DATA)))
LDFLAGS += $(addprefix -L,$(subst :, ,$(IDRIS2_LIBS)))
AR=ar

# Must match idris2-Text.ipkg's own `version` field -- there's no way
# for this standalone Makefile to read that ipkg field itself, so this
# is the one place the two have to be kept in sync by hand.
IDRIS2_TEXT_VERSION := 0.1.0
# Lazily (recursively) expanded on purpose: `idris2 --libdir` is only
# needed by the `install` target, and must not be invoked (or fail
# noisily, e.g. when idris2 isn't on PATH for an `all`/`clean`-only
# invocation) just because the Makefile was parsed.
LIBDIR = $(shell idris2 --libdir)/idris2-Text-$(IDRIS2_TEXT_VERSION)/lib

all: libidris2text.a

libidris2text.a: text_util.o
	$(AR) rcs $@ text_util.o

text_util.o: text_util.c text_util.h
	$(CC) $(CFLAGS) -c text_util.c -o text_util.o

# Run via idris2-Text.ipkg's `postinstall` hook (cwd = package root at
# that point, so this is invoked as `make -C support/c install`).
# idris2 --install itself only copies .ttc/.ttm/the .ipkg file -- it
# has no idea this package also ships a compiled C library, so
# something has to put it where Idris2's own packaging convention
# (idris2-src/docs/source/reference/packages.rst, "Support file
# install directories") expects: a package's own `lib` subdirectory.
install: all
	mkdir -p $(LIBDIR)
	cp libidris2text.a text_util.h $(LIBDIR)/

clean:
	rm -f libidris2text.a text_util.o
