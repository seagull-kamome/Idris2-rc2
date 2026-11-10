#pragma once

// The cell pool: per-thread heaps of 64 KiB size-class pages inside 4 MiB
// segments. Design, stages and limits: rc2/doc/small-object-allocator.md.
// The allocation and the release of the cells go through memory.h
// (idris2rc2_cellAlloc, idris2rc2_newConstructor, idris2rc2_cellFree and their
// inline forms); the rest is for the tests.

#include <stdalign.h>
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

#define IDRIS2RC2_POOL_SEG_SIZE ((size_t)4 << 20)
#define IDRIS2RC2_POOL_PAGE_BYTES ((size_t)64 << 10)

enum { IDRIS2RC2_PAGE_ACTIVE = 0, IDRIS2RC2_PAGE_FULL = 1, IDRIS2RC2_PAGE_EMPTY = 2 };

struct idris2rc2_Heap;

// One per 64 KiB page, kept in the header of the page's segment, not in the
// page: returning the page to the OS leaves it intact. Two cache lines: the
// first is the owner's alone, the second is written by other threads.
typedef struct idris2rc2_Page {
  void *free;       // free list, linked through the second word of a cell
  uint32_t used;    // cells handed out and neither released nor collected
  uint8_t klass;
  uint8_t state;    // IDRIS2RC2_PAGE_*
  uint16_t cellSize;
  char *bump;       // the part of the page not yet cut into cells
  char *end;
  char *base;
  struct idris2rc2_Page *next, *prev; // a list of the heap, or of the abandoned pages

  alignas(64) _Atomic(void *) thread_free; // cells released by other threads
  _Atomic(struct idris2rc2_Heap *) owner;
  atomic_int inPending;                    // linked on its owner's `pending`
  struct idris2rc2_Page *pendingNext;
} idris2rc2_Page;

typedef struct idris2rc2_Heap {
  idris2rc2_Page *direct[IDRIS2RC2_POOL_CLASSES]; // the page being allocated from
  idris2rc2_Page *avail[IDRIS2RC2_POOL_CLASSES];  // other pages with room
  idris2rc2_Page *full[IDRIS2RC2_POOL_CLASSES];
  idris2rc2_Page *empty, *emptyTail;              // pages with no live cell, newest first
  unsigned emptyCount;
  unsigned pagesHeld;
  struct idris2rc2_Heap *nextRetired;             // the list of the heaps of ended threads
  alignas(64) _Atomic(idris2rc2_Page *) pending;  // pages with released cells waiting
} idris2rc2_Heap;

// Starts as the static empty heap, whose pages hold nothing, so that the fast
// path needs no NULL test: a thread without a heap falls into the slow path.
extern __thread idris2rc2_Heap *idris2rc2_tlHeap;

extern bool idris2rc2_poolOn; // false: every cell is malloc'd

void *idris2rc2_poolAllocSlow(int klass);
void idris2rc2_poolFree(void *cell);

// Gives back what is empty now; for tests and long-running programs.
void idris2rc2_poolPurge(void);

// Pages in use (held by a heap, or abandoned with live cells) now and at the
// peak since the last reset, and the class of the page a pool cell is on
// (tests, and the check mode).
size_t idris2rc2_poolPagesInUse(void);
size_t idris2rc2_poolPagesPeak(void);
// Heap structures allocated over the life of the process (those of ended threads are reused).
size_t idris2rc2_poolHeapsCreated(void);
void idris2rc2_poolResetPeak(void);
int idris2rc2_poolPageClass(void *cell);

#ifdef IDRIS2RC2_POOL_CHECK
void idris2rc2_poolCheckAlloc(void *cell, int klass);
#endif

// The page descriptor of a pool cell: the descriptors are the first member of
// the segment header, one per 64 KiB page.
static inline idris2rc2_Page *idris2rc2_poolPageOf(void *cell) {
  uintptr_t seg = (uintptr_t)cell & ~(uintptr_t)(IDRIS2RC2_POOL_SEG_SIZE - 1);
  return (idris2rc2_Page *)seg + ((uintptr_t)cell - seg) / IDRIS2RC2_POOL_PAGE_BYTES;
}

// The rare cases of a release, out of line so that the common one stays small
// where it is inlined: a page that changes state, and a cell of another heap's page.
void idris2rc2_poolAfter(idris2rc2_Heap *h, idris2rc2_Page *pg);
void idris2rc2_poolFreeRemote(idris2rc2_Page *pg, void *cell);

// The release of a cell on the heap of its page, all of it plain.
static inline void idris2rc2_poolFreeInline(void *cell) {
  idris2rc2_Page *pg = idris2rc2_poolPageOf(cell);
  idris2rc2_Heap *h = idris2rc2_tlHeap;
  if (__builtin_expect(atomic_load_explicit(&pg->owner, memory_order_relaxed) != h, 0)) {
    idris2rc2_poolFreeRemote(pg, cell);
    return;
  }
  *(void **)((char *)cell + 8) = pg->free;
  pg->free = cell;
  pg->used--;
  if (__builtin_expect(pg->state != IDRIS2RC2_PAGE_ACTIVE ||
                       (pg->used == 0 && pg != h->direct[pg->klass]), 0))
    idris2rc2_poolAfter(h, pg);
}

static inline void *idris2rc2_poolAlloc(int klass) {
  idris2rc2_Page *pg = idris2rc2_tlHeap->direct[klass];
  void *c = pg->free;
  if (__builtin_expect(c != NULL, 1)) {
    pg->free = *(void **)((char *)c + 8);
    pg->used++;
#ifdef IDRIS2RC2_POOL_CHECK
    idris2rc2_poolCheckAlloc(c, klass);
#endif
    return c;
  }
  return idris2rc2_poolAllocSlow(klass);
}
