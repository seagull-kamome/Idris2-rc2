CC=gcc
CFLAGS+=-fPIC -Wall -Wextra -O2
# idris2rc2_util.h lives under idris2's own data dir -- ask idris2 itself
# instead of requiring IDRIS2_DATA to be set in the environment.
CFLAGS  += -I$(shell idris2 --libdir)/support/rc2
CFLAGS  += -I$(shell idris2 --libdir)/support/c
CFLAGS  += -I.
AR=ar

# Must match web.ipkg's own `version` field.
WEB_VERSION := 0.1.0
LIBDIR = $(shell idris2 --libdir)/web-$(WEB_VERSION)/lib

OBJS = idris2rc2_web_curl_util.o
HDRS = idris2rc2_web_curl_util.h

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

all: libidris2rc2web.a

libidris2rc2web.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

idris2rc2_web_curl_util.o: idris2rc2_web_curl_util.c idris2rc2_web_curl_util.h

install: all
	mkdir -p $(LIBDIR)
	cp libidris2rc2web.a $(HDRS) $(LIBDIR)/

clean:
	rm -f libidris2rc2web.a $(OBJS)
