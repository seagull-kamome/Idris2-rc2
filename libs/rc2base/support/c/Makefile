CC=gcc
CFLAGS+=-fPIC -Wall -Wextra -O2
CFLAGS  += $(addprefix -I,$(subst :, ,$(IDRIS2_DATA)))
LDFLAGS += $(addprefix -L,$(subst :, ,$(IDRIS2_LIBS)))
AR=ar

# Must match rc2base.ipkg's own `version` field.
RC2BASE_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/rc2base-$(RC2BASE_VERSION)/lib

OBJS = text_util.o concurrency_util.o xoroshiro64starstar.o xoroshiro128plusplus.o memstream.o event_util.o net_util.o
HDRS = text_util.h concurrency_util.h xoroshiro64starstar.h xoroshiro128plusplus.h memstream.h ptr_util.h event_util.h net_util.h


%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all: libidris2rc2base.a

libidris2rc2base.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

text_util.o: text_util.c text_util.h
concurrency_util.o: concurrency_util.c concurrency_util.h
xoroshiro64starstar.o: xoroshiro64starstar.c xoroshiro64starstar.h f2x.c
xoroshiro128plusplus.o: xoroshiro128plusplus.c xoroshiro128plusplus.h f2x.c
memstream.o: memstream.c memstream.h
event_util.o: event_util.c event_util.h
net_util.o: net_util.c net_util.h

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2base.a $(HDRS) $(LIBDIR)/

clean:
	rm -f libidris2rc2base.a $(OBJS)
