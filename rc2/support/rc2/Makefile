# Standalone Makefile for the rc2 backend's C runtime (libidris2rc2.a).
# Not coupled to the idris2 compiler's own build system, since rc2 is an
# independent external backend, not something merged into idris2-src.

CC ?= cc
AR ?= ar
RANLIB ?= ranlib
CFLAGS += -O2 -Wall -Wno-unused-function
INSTALL_ROOT ?= $(shell idris2 --libdir)/support/rc2
PREFIX ?= ${shell idris2 --prefix}

TARGET = libidris2rc2.a

# Every file is listed by name on purpose: a glob would silently pick up
# (or silently miss) a stray, stale or half-written file. Adding a source or
# a header to the runtime means adding it here too.
SRCS = \
	idris2rc2_buffer.c \
	idris2rc2_caf_memoize.c \
	idris2rc2_clock.c \
	idris2rc2_ioprims.c \
	idris2rc2_memory.c \
	idris2rc2_numeric.c \
	idris2rc2_rt.c \
	idris2rc2_strings.c \
	idris2rc2_utf8.c \
	idris2rc2_util.c \
	idris_net.c
OBJS = $(SRCS:.c=.o)

HDRS = \
	idris2rc2_buffer.h \
	idris2rc2_caf_memoize.h \
	idris2rc2_clock.h \
	idris2rc2_datatypes.h \
	idris2rc2_ioprims.h \
	idris2rc2_memory.h \
	idris2rc2_numeric.h \
	idris2rc2_rt.h \
	idris2rc2_runtime.h \
	idris2rc2_strings.h \
	idris2rc2_utf8.h \
	idris2rc2_util.h \
	idris_net.h

# The compiler application that `idris2 --build rc2.ipkg` leaves in
# ../../build/exec (installed next to the idris2 binary).
APPDIR = ../../build/exec
APP_FILES = \
	compileChez \
	idris2-rc2.so \
	idris2-rc2.ss \
	libidris2_support.so

GMP_CFLAGS := $(shell pkg-config --cflags gmp 2>/dev/null)
GMP_LIBS := $(shell pkg-config --libs gmp 2>/dev/null || echo -lgmp)
CFLAGS += $(GMP_CFLAGS)

.PHONY: all
all: $(TARGET)

$(TARGET): $(OBJS)
	$(AR) rc $@ $^
	$(RANLIB) $@

# Every object depends on every header: a layout change in
# idris2rc2_datatypes.h must recompile all of them.
$(OBJS): $(HDRS)

%.o: %.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

.PHONY: install
install: $(TARGET)
	echo Installing to ${PREFIX} ...
	install -d $(INSTALL_ROOT) ${PREFIX}/bin/idris2-rc2_app
	install -m 644 $(TARGET) $(HDRS) $(INSTALL_ROOT)
	for f in $(APP_FILES); do install $(APPDIR)/idris2-rc2_app/$$f $(PREFIX)/bin/idris2-rc2_app/$$f || exit 1; done
	install -m 755 $(APPDIR)/idris2-rc2 $(PREFIX)/bin/

.PHONY: clean
clean:
	$(RM) $(OBJS) $(TARGET)
