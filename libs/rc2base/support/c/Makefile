CC=gcc
CXX=g++
CFLAGS+=-fPIC -Wall -Wextra -O2
CFLAGS  += $(addprefix -I,$(subst :, ,$(IDRIS2_DATA)))
LDFLAGS += $(addprefix -L,$(subst :, ,$(IDRIS2_LIBS)))
AR=ar

comma := ,

RE2_CFLAGS  := $(shell pkg-config --cflags re2 2>/dev/null)
RE2_LIBS    := $(shell pkg-config --libs re2 2>/dev/null)
RE2_LIBDIRS := $(patsubst -L%,%,$(filter -L%,$(RE2_LIBS)))
RE2_RPATH   := $(addprefix -Wl$(comma)-rpath$(comma),$(RE2_LIBDIRS))

# Must match rc2base.ipkg's own `version` field.
RC2BASE_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/rc2base-$(RC2BASE_VERSION)/lib


%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all: libidris2rc2base.a libidris2rc2re2.so

libidris2rc2base.a: text_util.o concurrency_util.o xoroshiro64starstar.o xoroshiro128plusplus.o memstream.o event_util.o
	$(AR) rcs $@ text_util.o concurrency_util.o xoroshiro64starstar.o xoroshiro128plusplus.o memstream.o event_util.o

text_util.o: text_util.c text_util.h
concurrency_util.o: concurrency_util.c concurrency_util.h
xoroshiro64starstar.o: xoroshiro64starstar.c xoroshiro64starstar.h f2x.c
xoroshiro128plusplus.o: xoroshiro128plusplus.c xoroshiro128plusplus.h f2x.c
memstream.o: memstream.c memstream.h
event_util.o: event_util.c event_util.h

# re2's own API is C++, and pulls in dozens of abseil -l flags via
# pkg-config -- not something rc2's single %foreign `lib` field could
# name directly (see doc/regex.md). Kept as its own shared object
# rather than folded into libidris2rc2base.a so that one lib name is
# all a %foreign declaration needs; the embedded rpath points at this
# build's own libre2/abseil location so a consumer doesn't need
# LD_LIBRARY_PATH set up, at the cost of tying the .so to this
# machine's nix store (acceptable for this project's own dev-
# environment scope).
re2_util.o: re2_util.cpp re2_util.h
	$(CXX) -fPIC -Wall -Wextra -O2 $(RE2_CFLAGS) -std=c++17 -c re2_util.cpp -o re2_util.o

libidris2rc2re2.so: re2_util.o
	$(CXX) -shared -fPIC -o $@ re2_util.o $(RE2_LIBS) $(RE2_RPATH)

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2base.a text_util.h concurrency_util.h xoroshiro64starstar.h xoroshiro128plusplus.h memstream.h ptr_util.h event_util.h $(LIBDIR)/
	cp libidris2rc2re2.so re2_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2base.a text_util.o concurrency_util.o xoroshiro64starstar.o xoroshiro128plusplus.o memstream.o event_util.o libidris2rc2re2.so re2_util.o
