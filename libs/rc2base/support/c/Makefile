CC=gcc
CFLAGS+=-fPIC -Wall -Wextra -O2
# idris2rc2_util.h lives under idris2's own data dir -- ask idris2 itself
# instead of requiring IDRIS2_DATA to be set in the environment (idris2
# resolves this the same way by default, relative to its own prefix).
CFLAGS  += -I$(shell idris2 --libdir)/support/rc2
CFLAGS  += -I$(shell idris2 --libdir)/support/c
CFLAGS  += -I.
AR=ar

# Must match rc2base.ipkg's own `version` field.
RC2BASE_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/rc2base-$(RC2BASE_VERSION)/lib

OBJS = idris2rc2_rc2base_text_util.o idris2rc2_rc2base_concurrency_util.o idris2rc2_rc2base_xoroshiro64starstar.o idris2rc2_rc2base_xoroshiro128plusplus.o idris2rc2_rc2base_memstream.o idris2rc2_rc2base_event_util.o idris2rc2_rc2base_net_util.o idris2rc2_rc2base_posix_regex.o idris2rc2_rc2base_string_rc2.o idris2rc2_rc2base_double_convert.o
HDRS = idris2rc2_rc2base_text_util.h idris2rc2_rc2base_concurrency_util.h idris2rc2_rc2base_xoroshiro64starstar.h idris2rc2_rc2base_xoroshiro128plusplus.h idris2rc2_rc2base_memstream.h idris2rc2_rc2base_ptr_util.h idris2rc2_rc2base_event_util.h idris2rc2_rc2base_net_util.h idris2rc2_rc2base_posix_regex.h idris2rc2_rc2base_string_rc2.h idris2rc2_rc2base_double_convert.h


%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all: libidris2rc2base.a

libidris2rc2base.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

idris2rc2_rc2base_text_util.o: idris2rc2_rc2base_text_util.c idris2rc2_rc2base_text_util.h
idris2rc2_rc2base_concurrency_util.o: idris2rc2_rc2base_concurrency_util.c idris2rc2_rc2base_concurrency_util.h
idris2rc2_rc2base_xoroshiro64starstar.o: idris2rc2_rc2base_xoroshiro64starstar.c idris2rc2_rc2base_xoroshiro64starstar.h idris2rc2_rc2base_f2x.c
idris2rc2_rc2base_xoroshiro128plusplus.o: idris2rc2_rc2base_xoroshiro128plusplus.c idris2rc2_rc2base_xoroshiro128plusplus.h idris2rc2_rc2base_f2x.c
idris2rc2_rc2base_memstream.o: idris2rc2_rc2base_memstream.c idris2rc2_rc2base_memstream.h
idris2rc2_rc2base_event_util.o: idris2rc2_rc2base_event_util.c idris2rc2_rc2base_event_util.h
idris2rc2_rc2base_net_util.o: idris2rc2_rc2base_net_util.c idris2rc2_rc2base_net_util.h
idris2rc2_rc2base_posix_regex.o: idris2rc2_rc2base_posix_regex.c idris2rc2_rc2base_posix_regex.h
idris2rc2_rc2base_string_rc2.o: idris2rc2_rc2base_string_rc2.c idris2rc2_rc2base_string_rc2.h
idris2rc2_rc2base_double_convert.o: idris2rc2_rc2base_double_convert.c idris2rc2_rc2base_double_convert.h idris2rc2_rc2base_pow5_table.h idris2rc2_rc2base_cached_powers.h

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2base.a $(HDRS) $(LIBDIR)/

clean:
	rm -f libidris2rc2base.a $(OBJS)
