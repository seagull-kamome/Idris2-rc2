# Standalone Makefile for the rc2 backend's C runtime (libidris2rc2.a, and
# shared/libidris2rc2.so for `--directive sharedlib`/`sharedruntime`,
# rc2/doc/library-output.md).
# Not coupled to the idris2 compiler's own build system, since rc2 is an
# independent external backend, not something merged into idris2-src.

CC ?= cc
AR ?= ar
RANLIB ?= ranlib
CFLAGS += -O2 -Wall -Wno-unused-function
INSTALL_ROOT ?= $(shell idris2 --libdir)/support/rc2
PREFIX ?= ${shell idris2 --prefix}

TARGET = libidris2rc2.a
# In a directory of its own: a plain `-lidris2rc2` must keep finding the archive.
SHARED = shared/libidris2rc2.so

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
	idris2rc2_pool.c \
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
	idris2rc2_pool.h \
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
all: $(TARGET) $(SHARED)

$(TARGET): $(OBJS)
	$(AR) rc $@ $^
	$(RANLIB) $@

# Every object depends on every header: a layout change in
# idris2rc2_datatypes.h must recompile all of them.
$(OBJS): $(HDRS)

%.o: %.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

# The same sources, position independent, as one shared library: the single
# copy of the runtime that a host and the libraries it loads all use.
PIC_OBJS = $(addprefix pic/,$(OBJS))

$(PIC_OBJS): $(HDRS)

pic/%.o: %.c
	@mkdir -p pic
	$(CC) $(CFLAGS) -fPIC $(CPPFLAGS) -c $< -o $@

$(SHARED): $(PIC_OBJS)
	@mkdir -p shared
	$(CC) -shared -o $@ $^ $(GMP_LIBS) -lm -lpthread -Wl,-soname,libidris2rc2.so

.PHONY: install
install: $(TARGET) $(SHARED)
	echo Installing to ${PREFIX} ...
	install -d $(INSTALL_ROOT) ${PREFIX}/bin/idris2-rc2_app
	install -m 644 $(TARGET) $(HDRS) $(INSTALL_ROOT)
	install -d $(INSTALL_ROOT)/shared
	install -m 755 $(SHARED) $(INSTALL_ROOT)/shared
	for f in $(APP_FILES); do install $(APPDIR)/idris2-rc2_app/$$f $(PREFIX)/bin/idris2-rc2_app/$$f || exit 1; done
	install -m 755 $(APPDIR)/idris2-rc2 $(PREFIX)/bin/


.PHONY: install_norepl
install_norepl: $(TARGET)
	echo Installing to ${PREFIX} ...
	install -m 755 $(APPDIR)/idris2-rc2-norepl $(PREFIX)/bin/idris2-rc2-norepl.bin
	install -m 744 idris2-rc2-norepl $(PREFIX)/bin/


.PHONY: clean
clean:
	$(RM) $(OBJS) $(TARGET)
	$(RM) -r pic shared
