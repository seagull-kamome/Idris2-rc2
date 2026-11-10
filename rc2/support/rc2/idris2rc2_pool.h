#pragma once

// The cell pool: per-thread heaps of 64 KiB size-class pages inside 4 MiB
// segments. Design, stages and limits: rc2/doc/small-object-allocator.md.
// Only idris2rc2_cellAlloc / idris2rc2_cellFree (memory.c) use this.

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define IDRIS2RC2_POOL_MIN_CELL 16
#define IDRIS2RC2_POOL_MAX_CELL 128
#define IDRIS2RC2_POOL_CLASSES 15 // 16, 24, ..., 128

// Class of a cell of `size` bytes, or -1 if it is too big for the pool.
static inline int idris2rc2_poolClass(size_t size) {
  if (size > IDRIS2RC2_POOL_MAX_CELL) return -1;
  if (size <= IDRIS2RC2_POOL_MIN_CELL) return 0;
  return (int)((size + 7) / 8) - 2;
}

enum { IDRIS2RC2_PAGE_ACTIVE = 0, IDRIS2RC2_PAGE_FULL = 1, IDRIS2RC2_PAGE_EMPTY = 2 };

struct idris2rc2_Heap;

// One per 64 KiB page. Lives in the header of the page's segment, not in the
// page, so it does not move with the cells.
typedef struct idris2rc2_Page {
  void *free;       // free list, linked through the second word of a cell
  uint32_t used;    // cells handed out and not yet released or collected
  uint8_t klass;
  uint8_t state;    // IDRIS2RC2_PAGE_*
  uint16_t cellSize;
  char *bump;       // the part of the page not yet cut into cells
  char *end;
  char *base;
  _Atomic(void *) thread_free;                  // cells released by other threads
  _Atomic(struct idris2rc2_Heap *) owner;
  atomic_int inPending;                         // on the owner's `pending` stack
  struct idris2rc2_Page *pendingNext;
  struct idris2rc2_Page *next, *prev;           // the heap's list of this class
} idris2rc2_Page;

typedef struct idris2rc2_Heap {
  idris2rc2_Page *direct[IDRIS2RC2_POOL_CLASSES]; // the page being allocated from
  idris2rc2_Page *avail[IDRIS2RC2_POOL_CLASSES];  // other pages with room
  idris2rc2_Page *full[IDRIS2RC2_POOL_CLASSES];
  idris2rc2_Page *empty;                          // pages with no live cell
  _Atomic(idris2rc2_Page *) pending;              // pages with released cells waiting
} idris2rc2_Heap;

// Starts as the static empty heap, whose pages hold nothing, so that the fast
// path needs no NULL test: a thread without a heap falls into the slow path.
extern __thread idris2rc2_Heap *idris2rc2_tlHeap;

extern bool idris2rc2_poolOn; // false: every cell is malloc'd (IDRIS2RC2_POOL=0)

void *idris2rc2_poolAllocSlow(int klass);
void idris2rc2_poolFree(void *cell, int klass);

static inline void *idris2rc2_poolAlloc(int klass) {
  idris2rc2_Page *pg = idris2rc2_tlHeap->direct[klass];
  void *c = pg->free;
  if (__builtin_expect(c != NULL, 1)) {
    pg->free = *(void **)((char *)c + 8);
    pg->used++;
    return c;
  }
  return idris2rc2_poolAllocSlow(klass);
}
