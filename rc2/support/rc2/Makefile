# Standalone Makefile for the rc2 backend's C runtime (libidris2rc2.a).
# Not coupled to the idris2 compiler's own build system, since rc2 is an
# independent external backend, not something merged into idris2-src.

CC ?= cc
AR ?= ar
RANLIB ?= ranlib
CFLAGS += -O2 -Wall -Wno-unused-function
INSTALL_ROOT ?= $(shell idris2 --libdir)/support/rc2
IDRIS2_PREFIX ?= ${shell idris2 --prefix}

TARGET = libidris2rc2.a
SRCS := $(wildcard *.c)
OBJS = $(SRCS:.c=.o)

GMP_CFLAGS := $(shell pkg-config --cflags gmp 2>/dev/null)
GMP_LIBS := $(shell pkg-config --libs gmp 2>/dev/null || echo -lgmp)
CFLAGS += $(GMP_CFLAGS)

.PHONY: all
all: $(TARGET)

$(TARGET): $(OBJS)
	$(AR) rc $@ $^
	$(RANLIB) $@

%.o: %.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

.PHONY: install
install: $(TARGET)
	install -d $(INSTALL_ROOT) ${IDRIS2_PREFIX}//bin/idris2-rc2_app
	install -m 644 $(TARGET) *.h $(INSTALL_ROOT)
	install ../../build/exec/idris2-rc2_app/* $(IDRIS2_PREFIX)/bin/idris2-rc2_app
	install -m 755 ../../build/exec/idris2-rc2 $(IDRIS2_PREFIX)/bin/

.PHONY: clean
clean:
	$(RM) $(OBJS) $(TARGET)
