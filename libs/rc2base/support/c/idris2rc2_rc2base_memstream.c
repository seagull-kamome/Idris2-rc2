#include "memstream.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct idris2rc2_MemStream {
    FILE *fp;
    char *buf;
    size_t len;
};

idris2rc2_MemStream *idris2rc2_memstream_open(void) {
    idris2rc2_MemStream *m = malloc(sizeof *m);
    if (m == NULL) return NULL;
    m->buf = NULL;
    m->len = 0;
    m->fp = open_memstream(&m->buf, &m->len);
    if (m->fp == NULL) {
        free(m);
        return NULL;
    }
    return m;
}

void *idris2rc2_memstream_filep(idris2rc2_MemStream *m) {
    return m == NULL ? NULL : (void *) m->fp;
}

void idris2rc2_memstream_close(idris2rc2_MemStream *m) {
    if (m != NULL) fclose(m->fp);
}

void *idris2rc2_memstream_data(idris2rc2_MemStream *m) {
    return m == NULL ? NULL : (void *) m->buf;
}

long idris2rc2_memstream_size(idris2rc2_MemStream *m) {
    return m == NULL ? -1 : (long) m->len;
}

void idris2rc2_memstream_free(idris2rc2_MemStream *m) {
    if (m != NULL) {
        free(m->buf);
        free(m);
    }
}

/* Idris2's own `Buffer` -- {int size; char data[];} at the C level on
 * both RefC (idris2-src/support/refc/buffer.h) and rc2
 * (rc2/support/rc2/buffer.h, explicitly "ported from RefC's
 * support/refc/buffer.c", operating on "purely the raw malloc'd
 * buffer") -- deliberately identical, so a `Buffer` reaching this shim
 * as a bare AnyPtr on either backend is safe to reinterpret this way. */
struct idris2rc2_Buffer {
    int size;
    char data[];
};

void idris2rc2_memstream_copy_into_buffer(idris2rc2_MemStream *m, void *buf) {
    memcpy(((struct idris2rc2_Buffer *) buf)->data, m->buf, m->len);
}
