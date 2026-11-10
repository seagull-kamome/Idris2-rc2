#include "idris2rc2_pool.h"
#include "idris2rc2_datatypes.h"
#include "idris2rc2_util.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

// See rc2/doc/small-object-allocator.md. Stage 1a: a heap per thread, local
// and remote release, no return of memory to the OS, and the pages of a thread
// that ends stay with its heap (stages 1b and 1c).

#define SEG_SIZE ((size_t)4 << 20)
#define PAGE_BYTES ((size_t)64 << 10)
#define PAGES_PER_SEG 64
#define CARVE_BATCH 64

// Page 0 of a segment holds this header; pages 1..63 hold cells.
typedef struct {
  idris2rc2_Page pages[PAGES_PER_SEG];
  unsigned nextPage;
} Segment;
_Static_assert(sizeof(Segment) <= PAGE_BYTES, "the segment header fits in page 0");

bool idris2rc2_poolOn = true;

static idris2rc2_Page dummyPage;
static idris2rc2_Heap emptyHeap = {.direct = {[0 ... IDRIS2RC2_POOL_CLASSES - 1] = &dummyPage}};
__thread idris2rc2_Heap *idris2rc2_tlHeap = &emptyHeap;

static pthread_mutex_t segLock = PTHREAD_MUTEX_INITIALIZER;
static Segment *curSeg;

__attribute__((constructor)) static void poolInit(void) {
#ifdef IDRIS2RC2_NO_POOL
  idris2rc2_poolOn = false;
#else
  char const *e = getenv("IDRIS2RC2_POOL");
  if (e && e[0] == '0') idris2rc2_poolOn = false;
#endif
}

static inline void *nextOf(void *cell) { return *(void **)((char *)cell + 8); }
static inline void setNext(void *cell, void *next) { *(void **)((char *)cell + 8) = next; }

// ---- segments and pages ----

static Segment *segNew(void) {
  void *m = mmap(NULL, 2 * SEG_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  IDRIS2RC2_VERIFY(m != MAP_FAILED, "cell pool: mmap failed");
  uintptr_t lo = (uintptr_t)m, a = (lo + SEG_SIZE - 1) & ~(uintptr_t)(SEG_SIZE - 1);
  if (a > lo) munmap(m, a - lo);
  if (lo + 2 * SEG_SIZE > a + SEG_SIZE) munmap((void *)(a + SEG_SIZE), lo + 2 * SEG_SIZE - (a + SEG_SIZE));
  Segment *s = (Segment *)a;
  s->nextPage = 1;
  return s;
}

static idris2rc2_Page *pageNew(void) {
  pthread_mutex_lock(&segLock);
  if (!curSeg || curSeg->nextPage == PAGES_PER_SEG) curSeg = segNew();
  Segment *s = curSeg;
  unsigned idx = s->nextPage++;
  pthread_mutex_unlock(&segLock);
  idris2rc2_Page *pg = &s->pages[idx];
  pg->base = (char *)s + idx * PAGE_BYTES;
  return pg;
}

static void pageInit(idris2rc2_Page *pg, idris2rc2_Heap *h, int k) {
  size_t cs = IDRIS2RC2_POOL_MIN_CELL + 8 * (size_t)k;
  pg->free = NULL;
  pg->used = 0;
  pg->klass = (uint8_t)k;
  pg->state = IDRIS2RC2_PAGE_ACTIVE;
  pg->cellSize = (uint16_t)cs;
  pg->bump = pg->base;
  pg->end = pg->base + (PAGE_BYTES / cs) * cs;
  atomic_store_explicit(&pg->owner, h, memory_order_relaxed);
  pg->next = pg->prev = NULL;
}

// ---- the heap's lists of pages ----

static void listPush(idris2rc2_Page **head, idris2rc2_Page *pg) {
  pg->prev = NULL;
  pg->next = *head;
  if (*head) (*head)->prev = pg;
  *head = pg;
}

static void listRemove(idris2rc2_Page **head, idris2rc2_Page *pg) {
  if (pg->prev) pg->prev->next = pg->next; else *head = pg->next;
  if (pg->next) pg->next->prev = pg->prev;
  pg->next = pg->prev = NULL;
}

static idris2rc2_Heap *heapNew(void) {
  idris2rc2_Heap *h = calloc(1, sizeof(idris2rc2_Heap));
  IDRIS2RC2_VERIFY(h, "cell pool: calloc failed");
  for (int k = 0; k < IDRIS2RC2_POOL_CLASSES; k++) h->direct[k] = &dummyPage;
  return h;
}

// ---- the owner's side ----

// Cuts the next cells of the page's untouched part into its free list, in
// address order, so a fresh page is touched as it is used and its cells come
// out in sequence.
static void carve(idris2rc2_Page *pg) {
  size_t cs = pg->cellSize;
  char *p = pg->bump, *first = p, *last = NULL;
  for (int n = 0; n < CARVE_BATCH && p + cs <= pg->end; n++) {
    if (last) setNext(last, p);
    last = p;
    p += cs;
  }
  if (last) {
    setNext(last, NULL);
    pg->free = first;
    pg->bump = p;
  }
}

// Takes the cells other threads have released into the free list. Only the
// owner calls this, and it takes the whole stack at once, so a pusher never
// sees a stale head linked in.
static void collect(idris2rc2_Page *pg) {
  void *x = atomic_exchange(&pg->thread_free, NULL);
  if (!x) return;
  uint32_t n = 1;
  void *t = x;
  while (nextOf(t)) {
    t = nextOf(t);
    n++;
  }
  setNext(t, pg->free);
  pg->free = x;
  pg->used -= n;
}

static void toEmpty(idris2rc2_Heap *h, idris2rc2_Page *pg) {
  pg->state = IDRIS2RC2_PAGE_EMPTY;
  pg->free = NULL;
  pg->bump = pg->end;
  listPush(&h->empty, pg);
}

// After a release or a collection: a full page with room goes back to the
// available list; a page with no live cell, other than the one being allocated
// from, becomes empty (and can serve any class).
static void pageAfter(idris2rc2_Heap *h, idris2rc2_Page *pg) {
  int k = pg->klass;
  if (pg->state == IDRIS2RC2_PAGE_FULL && pg->free) {
    listRemove(&h->full[k], pg);
    pg->state = IDRIS2RC2_PAGE_ACTIVE;
    listPush(&h->avail[k], pg);
  }
  if (pg->state == IDRIS2RC2_PAGE_ACTIVE && pg->used == 0 && pg != h->direct[k]) {
    listRemove(&h->avail[k], pg);
    toEmpty(h, pg);
  }
}

static void drainPending(idris2rc2_Heap *h) {
  idris2rc2_Page *p = atomic_exchange(&h->pending, NULL);
  while (p) {
    idris2rc2_Page *nx = p->pendingNext;
    // Clear the flag first, so a push that follows queues the page again.
    atomic_exchange(&p->inPending, 0);
    if (p->state != IDRIS2RC2_PAGE_EMPTY) {
      collect(p);
      pageAfter(h, p);
    }
    p = nx;
  }
}

static inline void *popCell(idris2rc2_Page *pg) {
  void *c = pg->free;
  pg->free = nextOf(c);
  pg->used++;
  return c;
}

void *idris2rc2_poolAllocSlow(int k) {
  idris2rc2_Heap *h = idris2rc2_tlHeap;
  if (h == &emptyHeap) {
    h = heapNew();
    idris2rc2_tlHeap = h;
  }
  idris2rc2_Page *pg = h->direct[k];
  for (;;) {
    if (pg != &dummyPage) {
      if (!pg->free) carve(pg);
      if (!pg->free) {
        drainPending(h);
        collect(pg);
      }
      if (pg->free) return popCell(pg);
      pg->state = IDRIS2RC2_PAGE_FULL;
      listPush(&h->full[k], pg);
    }
    // The cells other threads released come before a new page is taken, so a
    // producer and a consumer do not grow the heap without bound.
    drainPending(h);
    if (h->avail[k]) {
      pg = h->avail[k];
      listRemove(&h->avail[k], pg);
    } else if (h->empty) {
      pg = h->empty;
      listRemove(&h->empty, pg);
      pageInit(pg, h, k);
    } else {
      pg = pageNew();
      pageInit(pg, h, k);
    }
    h->direct[k] = pg;
  }
}

// ---- release ----

static void remotePush(idris2rc2_Page *pg, void *c) {
  void *old = atomic_load_explicit(&pg->thread_free, memory_order_relaxed);
  do {
    setNext(c, old);
  } while (!atomic_compare_exchange_weak(&pg->thread_free, &old, c));
  // Tell the owner there is something to collect, once until it has looked.
  if (!atomic_exchange(&pg->inPending, 1)) {
    idris2rc2_Heap *o = atomic_load_explicit(&pg->owner, memory_order_relaxed);
    idris2rc2_Page *top = atomic_load_explicit(&o->pending, memory_order_relaxed);
    do {
      pg->pendingNext = top;
    } while (!atomic_compare_exchange_weak(&o->pending, &top, pg));
  }
}

void idris2rc2_poolFree(void *c, int k) {
  Segment *seg = (Segment *)((uintptr_t)c & ~(uintptr_t)(SEG_SIZE - 1));
  idris2rc2_Page *pg = &seg->pages[((uintptr_t)c - (uintptr_t)seg) / PAGE_BYTES];
#ifdef IDRIS2RC2_POOL_CHECK
  {
    IDRIS2RC2_Header *hd = (IDRIS2RC2_Header *)c;
    IDRIS2RC2_VERIFY(!(hd->rc == 0xDEAD && hd->tag == 0xDE), "cell pool: double release of %p", c);
    IDRIS2RC2_VERIFY(pg->klass == k, "cell pool: class %d released as %d", (int)pg->klass, k);
    IDRIS2RC2_VERIFY(((char *)c - pg->base) % pg->cellSize == 0, "cell pool: %p is not a cell boundary", c);
    hd->rc = 0xDEAD;
    hd->tag = 0xDE;
  }
#endif
  idris2rc2_Heap *h = idris2rc2_tlHeap;
  if (atomic_load_explicit(&pg->owner, memory_order_relaxed) == h) {
    setNext(c, pg->free);
    pg->free = c;
    pg->used--;
    if (__builtin_expect(pg->state != IDRIS2RC2_PAGE_ACTIVE ||
                         (pg->used == 0 && pg != h->direct[pg->klass]), 0))
      pageAfter(h, pg);
  } else {
    remotePush(pg, c);
  }
  (void)k;
}
