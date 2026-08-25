CC=gcc
CFLAGS+=-fPIC -Wall -Wextra -O2
CFLAGS  += $(addprefix -I,$(subst :, ,$(IDRIS2_DATA)))
LDFLAGS += $(addprefix -L,$(subst :, ,$(IDRIS2_LIBS)))
AR=ar

# Must match rc2base.ipkg's own `version` field.
RC2BASE_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/rc2base-$(RC2BASE_VERSION)/lib

all: libidris2rc2base.a

libidris2rc2base.a: text_util.o concurrency_util.o
	$(AR) rcs $@ text_util.o concurrency_util.o

text_util.o: text_util.c text_util.h
	$(CC) $(CFLAGS) -c text_util.c -o text_util.o

concurrency_util.o: concurrency_util.c concurrency_util.h
	$(CC) $(CFLAGS) -c concurrency_util.c -o concurrency_util.o

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2base.a text_util.h concurrency_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2base.a text_util.o concurrency_util.o
