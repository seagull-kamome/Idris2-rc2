CC=gcc
CFLAGS=-fPIC -Wall -Wextra -O2
AR=ar

all: libidris2text.a

libidris2text.a: text_util.o
	$(AR) rcs $@ text_util.o

text_util.o: text_util.c text_util.h
	$(CC) $(CFLAGS) -c text_util.c -o text_util.o

clean:
	rm -f libidris2text.a text_util.o
