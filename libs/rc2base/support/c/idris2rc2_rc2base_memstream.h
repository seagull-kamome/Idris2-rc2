#ifndef MEMSTREAM_H
#define MEMSTREAM_H

typedef struct idris2rc2_MemStream idris2rc2_MemStream;

/* NULL on open_memstream(3)/allocation failure. */
idris2rc2_MemStream *idris2rc2_memstream_open(void);

/* The FILE* to hand to any C API's own "write to this FILE*" option
 * (e.g. libcurl's CURLOPT_WRITEDATA). */
void *idris2rc2_memstream_filep(idris2rc2_MemStream *m);

/* Flushes and finalizes the captured bytes -- call exactly once,
 * before any _data/_size/_copy_into_buffer call below. */
void idris2rc2_memstream_close(idris2rc2_MemStream *m);

/* NUL-terminated (open_memstream(3)'s own guarantee on close, the NUL
 * itself not counted in _size below) -- NULL only if
 * idris2rc2_memstream_open itself already returned NULL. */
void *idris2rc2_memstream_data(idris2rc2_MemStream *m);

/* Exact captured byte count, -1 if m is NULL. */
long idris2rc2_memstream_size(idris2rc2_MemStream *m);

/* Releases the handle and the captured buffer itself (plain free()).
 * Call once, after every _data/_size/_copy_into_buffer read is done. */
void idris2rc2_memstream_free(idris2rc2_MemStream *m);

/* memcpy's the captured bytes directly into an Idris2 `Buffer`'s own
 * native layout ({int size; char data[];}, shared identically between
 * RefC's and rc2's own runtime support -- see this file's own .c
 * companion). `buf` must already be sized to exactly m's own captured
 * length (idris2rc2_memstream_size). */
void idris2rc2_memstream_copy_into_buffer(idris2rc2_MemStream *m, void *buf);

#endif
