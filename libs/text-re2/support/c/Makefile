CXX=g++
AR=ar

comma := ,

RE2_CFLAGS  := $(shell pkg-config --cflags re2 2>/dev/null)
RE2_LIBS    := $(shell pkg-config --libs re2 2>/dev/null)
RE2_LIBDIRS := $(patsubst -L%,%,$(filter -L%,$(RE2_LIBS)))
RE2_RPATH   := $(addprefix -Wl$(comma)-rpath$(comma),$(RE2_LIBDIRS))

# Must match text-re2.ipkg's own `version` field.
TEXT_RE2_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/text-re2-$(TEXT_RE2_VERSION)/lib

all: libidris2rc2re2.so

# re2's own API is C++, and pulls in dozens of abseil -l flags via
# pkg-config -- not something a %foreign `lib` field could name
# directly (see doc/regex.md). Built as its own shared object so that
# one lib name (`libidris2rc2re2`, kept from when this lived in
# rc2base) is all a %foreign declaration needs; the embedded rpath
# points at this build's own libre2/abseil location so a consumer
# doesn't need LD_LIBRARY_PATH set up, at the cost of tying the .so to
# this machine's nix store (acceptable for this project's own dev-
# environment scope).
re2_util.o: re2_util.cpp re2_util.h
	$(CXX) -fPIC -Wall -Wextra -O2 $(RE2_CFLAGS) -std=c++17 -c re2_util.cpp -o re2_util.o

libidris2rc2re2.so: re2_util.o
	$(CXX) -shared -fPIC -o $@ re2_util.o $(RE2_LIBS) $(RE2_RPATH)

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2re2.so re2_util.h $(LIBDIR)/

clean:
	rm -f libidris2rc2re2.so re2_util.o
