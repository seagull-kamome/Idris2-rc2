#include "idris2rc2_pool.h"
#include "idris2rc2_datatypes.h"
#include "idris2rc2_util.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// See rc2/doc/small-object-allocator.md.

#define SEG_SIZE IDRIS2RC2_POOL_SEG_SIZE
#define PAGE_BYTES IDRIS2RC2_POOL_PAGE_BYTES
#define PAGES_PER_SEG 64
#define CARVE_BATCH 64
#define RETAIN_MIN_PAGES 64
#define POOL_DEAD ((idris2rc2_Page *)1) // the `pending` of a heap that has ended

// Page 0 of a segment holds this header; pages 1..63 hold cells. A segment is
// never unmapped: a thread that released a cell may still look at the page
// descriptor after the page has been emptied and returned.
typedef struct Segment {
  idris2rc2_Page pages[PAGES_PER_SEG];
  uint64_t freeMask; // bit i: page i is not held by any heap
  struct Segment *next;
} Segment;
_Static_assert(sizeof(Segment) <= PAGE_BYTES, "the segment header fits in page 0");
_Static_assert(offsetof(Segment, pages) == 0, "idris2rc2_poolPageOf takes the descriptors from the start of the segment");

#ifdef IDRIS2RC2_NO_POOL
bool idris2rc2_poolOn = false;
#else
bool idris2rc2_poolOn = true;
#endif

static idris2rc2_Page dummyPage;
static idris2rc2_Heap emptyHeap = {.direct = {[0 ... IDRIS2RC2_POOL_CLASSES - 1] = &dummyPage}};
static idris2rc2_Heap abandonedHeap = {.pending = POOL_DEAD};
__thread idris2rc2_Heap *idris2rc2_tlHeap = &emptyHeap;

// The segments, and the pages whose thread has ended with cells still live.
static pthread_mutex_t globalLock = PTHREAD_MUTEX_INITIALIZER;
static Segment *segments;
static idris2rc2_Page *abandoned[IDRIS2RC2_POOL_CLASSES];
static idris2rc2_Heap *retiredHeaps; // heaps of ended threads, for the next thread that needs one
static _Atomic size_t heapsCreated;
static _Atomic size_t pagesInUse, pagesPeak; // pages held by some heap, or abandoned with live cells

#define BATCH_MAX 64
static __thread struct {
  idris2rc2_Page *pg;
  void *head, *tail;
  uint32_t n;
  bool ended; // this thread has given its heap up; no more batching
} rb;

static void batchFlush(void);

// Before any other constructor can allocate a cell.
__attribute__((constructor(101))) static void poolInit(void) {
#ifndef IDRIS2RC2_NO_POOL
  char const *e = getenv("IDRIS2RC2_POOL");
  if (e && e[0] == '0') idris2rc2_poolOn = false;
#endif
}

static inline void *nextOf(void *cell) { return *(void **)((char *)cell + 8); }
static inline void setNext(void *cell, void *next) { *(void **)((char *)cell + 8) = next; }

static inline Segment *segmentOf(void *p) {
  return (Segment *)((uintptr_t)p & ~(uintptr_t)(SEG_SIZE - 1));
}

size_t idris2rc2_poolPagesInUse(void) { return atomic_load(&pagesInUse); }
size_t idris2rc2_poolPagesPeak(void) { return atomic_load(&pagesPeak); }
size_t idris2rc2_poolHeapsCreated(void) { return atomic_load(&heapsCreated); }
void idris2rc2_poolResetPeak(void) { atomic_store(&pagesPeak, atomic_load(&pagesInUse)); }
int idris2rc2_poolPageClass(void *cell) { return idris2rc2_poolPageOf(cell)->klass; }

// ---- check mode ----

#ifdef IDRIS2RC2_POOL_CHECK
#define CELL_FILL 0xDD
static void fillBody(void *cell, size_t cellSize) {
  memset((char *)cell + 16, CELL_FILL, cellSize - 16);
}
void idris2rc2_poolCheckAlloc(void *cell, int klass) {
  idris2rc2_Page *pg = idris2rc2_poolPageOf(cell);
  IDRIS2RC2_VERIFY(pg->klass == klass, "cell pool: class %d allocated from a page of class %d", klass, (int)pg->klass);
  for (size_t i = 16; i < pg->cellSize; i++)
    IDRIS2RC2_VERIFY(((unsigned char *)cell)[i] == CELL_FILL, "cell pool: %p written after its release (byte %zu)", cell, i);
}
#endif

// ---- segments and pages ----

static Segment *segNew(void) {
  void *m = mmap(NULL, 2 * SEG_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  IDRIS2RC2_VERIFY(m != MAP_FAILED, "cell pool: mmap failed");
  uintptr_t lo = (uintptr_t)m, a = (lo + SEG_SIZE - 1) & ~(uintptr_t)(SEG_SIZE - 1);
  if (a > lo) munmap(m, a - lo);
  if (lo + 2 * SEG_SIZE > a + SEG_SIZE) munmap((void *)(a + SEG_SIZE), lo + 2 * SEG_SIZE - (a + SEG_SIZE));
  Segment *s = (Segment *)a;
  s->freeMask = ~(uint64_t)1; // pages 1..63
  for (int i = 1; i < PAGES_PER_SEG; i++) s->pages[i].base = (char *)s + (size_t)i * PAGE_BYTES;
  return s;
}

// A page no heap holds: from the first segment that has one, so the memory stays in few segments.
static idris2rc2_Page *pageTake(void) {
  pthread_mutex_lock(&globalLock);
  Segment *s = segments;
  while (s && !s->freeMask) s = s->next;
  if (!s) {
    s = segNew();
    s->next = segments;
    segments = s;
  }
  int idx = __builtin_ctzll(s->freeMask);
  s->freeMask &= ~((uint64_t)1 << idx);
  pthread_mutex_unlock(&globalLock);
  size_t now = atomic_fetch_add(&pagesInUse, 1) + 1, peak = atomic_load(&pagesPeak);
  while (now > peak && !atomic_compare_exchange_weak(&pagesPeak, &peak, now)) {}
  return &s->pages[idx];
}

// Gives the page's memory back to the OS and the page to its segment. The
// page must have no live cell and nothing on thread_free.
static void pageReturn(idris2rc2_Page *pg) {
  // Nobody's: a stale entry for this page on the old owner's `pending` must
  // find that it is not that heap's any more (processPending).
  atomic_store(&pg->owner, &abandonedHeap);
  madvise(pg->base, PAGE_BYTES, MADV_DONTNEED);
  pg->state = IDRIS2RC2_PAGE_EMPTY;
  pg->free = NULL;
  pg->bump = pg->end = pg->base;
  Segment *s = segmentOf(pg);
  atomic_fetch_sub(&pagesInUse, 1);
  pthread_mutex_lock(&globalLock);
  s->freeMask |= (uint64_t)1 << (pg - s->pages);
  pthread_mutex_unlock(&globalLock);
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
  pg->next = pg->prev = NULL;
  atomic_store(&pg->owner, h); // last: it publishes the page to the stale entries and to the pushers
}

// ---- lists of pages ----

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

static void emptyPush(idris2rc2_Heap *h, idris2rc2_Page *pg) {
  pg->state = IDRIS2RC2_PAGE_EMPTY;
  pg->free = NULL;
  listPush(&h->empty, pg);
  if (!h->emptyTail) h->emptyTail = pg;
  h->emptyCount++;
}

static void emptyRemove(idris2rc2_Heap *h, idris2rc2_Page *pg) {
  if (h->emptyTail == pg) h->emptyTail = pg->prev;
  listRemove(&h->empty, pg);
  h->emptyCount--;
}

// A heap keeps this many empty pages for itself; the older ones go back. `force`:
// the heap has ended, nothing is queued on its `pending` any more.
static void emptyTrim(idris2rc2_Heap *h, unsigned retain, bool force) {
  while (h->emptyCount > retain) {
    idris2rc2_Page *pg = h->emptyTail;
    // An entry for it is on `pending` or on its way there: returned now, it
    // would carry the flag to the next heap that takes the page.
    if (!force && atomic_load(&pg->inPending)) break;
    emptyRemove(h, pg);
    h->pagesHeld--;
    pageReturn(pg);
  }
}

static inline unsigned retainOf(idris2rc2_Heap *h) {
  unsigned eighth = h->pagesHeld / 8;
  return eighth > RETAIN_MIN_PAGES ? eighth : RETAIN_MIN_PAGES;
}

// ---- the owner's side ----

// Cuts the next cells of the page's untouched part into its free list, in
// address order, so a fresh page is touched as it is used and its cells come
// out in sequence.
static void poolCarve(idris2rc2_Page *pg) {
  size_t cs = pg->cellSize;
  char *p = pg->bump, *first = p, *last = NULL;
  for (int n = 0; n < CARVE_BATCH && p + cs <= pg->end; n++) {
    if (last) setNext(last, p);
#ifdef IDRIS2RC2_POOL_CHECK
    fillBody(p, cs);
#endif
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
static void collectAll(idris2rc2_Page *pg) {
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

// The pre-check is only for the places that look speculatively. After
// `inPending` is cleared the load must not be relaxed: a pusher that saw the
// flag set relies on this collection to find its cell (collectAll).
static inline void poolCollect(idris2rc2_Page *pg) {
  if (atomic_load_explicit(&pg->thread_free, memory_order_relaxed)) collectAll(pg);
}

// After a release or a collection: a full page with room goes back to the
// available list; a page with no live cell, other than the one being allocated
// from, becomes empty and can serve any class.
static void pageAfter(idris2rc2_Heap *h, idris2rc2_Page *pg) {
  int k = pg->klass;
  if (pg->state == IDRIS2RC2_PAGE_FULL && pg->free) {
    listRemove(&h->full[k], pg);
    pg->state = IDRIS2RC2_PAGE_ACTIVE;
    listPush(&h->avail[k], pg);
  }
  if (pg->state == IDRIS2RC2_PAGE_ACTIVE && pg->used == 0 && pg != h->direct[k]) {
    listRemove(&h->avail[k], pg);
    emptyPush(h, pg);
    // Hysteresis: trim down to the retained number only after a quarter more.
    unsigned retain = retainOf(h);
    if (h->emptyCount > retain + retain / 4) emptyTrim(h, retain, false);
  }
}

static void processPending(idris2rc2_Heap *h, idris2rc2_Page *p) {
  while (p) {
    idris2rc2_Page *nx = p->pendingNext;
    // Clear the flag first, so a push that follows queues the page again.
    atomic_exchange(&p->inPending, 0);
    // A stale entry: the page was emptied, or passed to another heap, since.
    if (atomic_load(&p->owner) == h && p->state != IDRIS2RC2_PAGE_EMPTY) {
      collectAll(p);
      pageAfter(h, p);
    }
    p = nx;
  }
}

static void poolDrain(idris2rc2_Heap *h) {
  if (!atomic_load_explicit(&h->pending, memory_order_relaxed)) return;
  processPending(h, atomic_exchange(&h->pending, NULL));
}

static inline void *popCell(idris2rc2_Page *pg) {
  void *c = pg->free;
  pg->free = nextOf(c);
  pg->used++;
  return c;
}

// ---- threads that end ----

static idris2rc2_Page *adopt(idris2rc2_Heap *h, int k) {
  pthread_mutex_lock(&globalLock);
  idris2rc2_Page *pg = abandoned[k];
  if (pg) listRemove(&abandoned[k], pg);
  pthread_mutex_unlock(&globalLock);
  if (!pg) return NULL;
  pg->state = IDRIS2RC2_PAGE_ACTIVE;
  atomic_store(&pg->owner, h);
  h->pagesHeld++;
  poolCollect(pg);
  return pg;
}

// Takes the abandoned pages that have something on thread_free, collects them
// and returns the ones that become empty, so that a thread about to take a new
// page can use them.
static void sweepAbandoned(void) {
  idris2rc2_Page *taken = NULL;
  pthread_mutex_lock(&globalLock);
  for (int k = 0; k < IDRIS2RC2_POOL_CLASSES; k++) {
    for (idris2rc2_Page *pg = abandoned[k], *nx; pg; pg = nx) {
      nx = pg->next;
      if (atomic_load(&pg->thread_free)) {
        listRemove(&abandoned[k], pg);
        pg->next = taken;
        taken = pg;
      }
    }
  }
  pthread_mutex_unlock(&globalLock);
  while (taken) {
    idris2rc2_Page *pg = taken, *nx = pg->next;
    pg->next = pg->prev = NULL;
    poolCollect(pg);
    if (pg->used == 0) {
      pageReturn(pg);
    } else {
      pthread_mutex_lock(&globalLock);
      listPush(&abandoned[pg->klass], pg);
      pthread_mutex_unlock(&globalLock);
    }
    taken = nx;
  }
}

static idris2rc2_Page *takePage(idris2rc2_Heap *h, int k) {
  idris2rc2_Page *pg = h->avail[k];
  if (pg) {
    listRemove(&h->avail[k], pg);
    return pg;
  }
  if (h->empty) {
    pg = h->empty;
    emptyRemove(h, pg);
    pageInit(pg, h, k);
    return pg;
  }
  pg = adopt(h, k);
  if (pg) return pg;
  // Cells of a full page whose entry is delayed (a stale flag, see queuePage)
  // are found here; only the first few pages are looked at.
  int looked = 0;
  for (idris2rc2_Page *f = h->full[k], *nx; f && looked < 16; f = nx, looked++) {
    nx = f->next;
    poolCollect(f);
    pageAfter(h, f);
  }
  if (h->avail[k]) {
    pg = h->avail[k];
    listRemove(&h->avail[k], pg);
    return pg;
  }
  sweepAbandoned();
  pg = pageTake();
  h->pagesHeld++;
  pageInit(pg, h, k);
  return pg;
}

static pthread_key_t heapKey;
static pthread_once_t heapKeyOnce = PTHREAD_ONCE_INIT;
static void heapEnd(void *heap);
static void heapKeyInit(void) { IDRIS2RC2_VERIFY(pthread_key_create(&heapKey, heapEnd) == 0, "cell pool: pthread_key_create failed"); }

static void heapReset(idris2rc2_Heap *h) {
  for (int k = 0; k < IDRIS2RC2_POOL_CLASSES; k++) {
    h->direct[k] = &dummyPage;
    h->avail[k] = h->full[k] = NULL;
  }
  h->empty = h->emptyTail = NULL;
  h->emptyCount = 0;
  h->pagesHeld = 0;
  h->nextRetired = NULL;
  atomic_store(&h->pending, NULL); // last: it makes the heap live
}

// The heap of an ended thread if there is one (its memory is never given back:
// a thread that released a cell to one of its pages may still read its `pending`),
// else a new one.
static idris2rc2_Heap *heapNew(void) {
  pthread_mutex_lock(&globalLock);
  idris2rc2_Heap *h = retiredHeaps;
  if (h) retiredHeaps = h->nextRetired;
  pthread_mutex_unlock(&globalLock);
  if (!h) {
    h = aligned_alloc(64, (sizeof(idris2rc2_Heap) + 63) & ~(size_t)63);
    IDRIS2RC2_VERIFY(h, "cell pool: allocation of a heap failed");
    atomic_fetch_add_explicit(&heapsCreated, 1, memory_order_relaxed);
  }
  heapReset(h);
  pthread_once(&heapKeyOnce, heapKeyInit);
  IDRIS2RC2_VERIFY(pthread_setspecific(heapKey, h) == 0, "cell pool: pthread_setspecific failed");
  return h;
}

// A thread ends: its pages with live cells are passed on, the rest returned.
// No other thread pushes to this heap's `pending` after the first step. The
// heap is reused later (heapNew): a thread that still holds its address finds
// POOL_DEAD there until then, afterwards a live heap that does not own its page,
// whose processPending skips the entry.
static void heapAbandon(idris2rc2_Heap *h) {
  processPending(h, atomic_exchange(&h->pending, POOL_DEAD));
  for (int k = 0; k < IDRIS2RC2_POOL_CLASSES; k++) {
    idris2rc2_Page *lists[3] = {h->direct[k] == &dummyPage ? NULL : h->direct[k], h->avail[k], h->full[k]};
    h->direct[k] = &dummyPage;
    h->avail[k] = h->full[k] = NULL;
    for (int l = 0; l < 3; l++) {
      for (idris2rc2_Page *pg = lists[l], *nx; pg; pg = nx) {
        nx = l == 0 ? NULL : pg->next;
        pg->next = pg->prev = NULL;
        poolCollect(pg);
        if (pg->used == 0) {
          pageReturn(pg);
        } else {
          pg->state = IDRIS2RC2_PAGE_ACTIVE;
          atomic_store(&pg->owner, &abandonedHeap);
          pthread_mutex_lock(&globalLock);
          listPush(&abandoned[k], pg);
          pthread_mutex_unlock(&globalLock);
        }
      }
    }
  }
  emptyTrim(h, 0, true);
  h->pagesHeld = 0;
}

// Another key's destructor may still allocate and release cells while the
// thread ends, and the order of the destructors is not fixed: the heap is
// kept through the first rounds and given up in the last but one (ThreadSanitizer
// finishes the thread in the last, and fails on a mutex taken after that).
static void heapEnd(void *heap) {
  static __thread int rounds;
  // Whatever the round, cells released so far reach their pages. Those released
  // by a destructor that runs after the last call of this one stay in the batch.
  batchFlush();
  if (++rounds < PTHREAD_DESTRUCTOR_ITERATIONS - 1) {
    pthread_setspecific(heapKey, heap);
    return;
  }
  if (idris2rc2_tlHeap == heap) idris2rc2_tlHeap = &emptyHeap;
  rb.ended = true;
  idris2rc2_Heap *h = heap;
  heapAbandon(h);
  // No page names this heap as its owner any more (they were returned or given to
  // `abandonedHeap`), so a stale entry on another heap's `pending` is skipped by
  // the owner test, and a pusher that still holds the heap finds POOL_DEAD there
  // or, once it is reused, a live heap that does not own its page.
  pthread_mutex_lock(&globalLock);
  h->nextRetired = retiredHeaps;
  retiredHeaps = h;
  pthread_mutex_unlock(&globalLock);
}

void *idris2rc2_poolAllocSlow(int k) {
  batchFlush();
  if (!idris2rc2_poolOn) {
    void *c = malloc(IDRIS2RC2_POOL_MIN_CELL + 8 * (size_t)k);
    IDRIS2RC2_VERIFY(c, "allocation failed");
    return c;
  }
  idris2rc2_Heap *h = idris2rc2_tlHeap;
  if (h == &emptyHeap) {
    h = heapNew();
    idris2rc2_tlHeap = h;
  }
  idris2rc2_Page *pg = h->direct[k];
  for (;;) {
    if (pg != &dummyPage) {
      if (!pg->free) poolCarve(pg);
      if (!pg->free) {
        poolDrain(h);
        poolCollect(pg);
      }
      if (pg->free) {
#ifdef IDRIS2RC2_POOL_CHECK
        void *c = popCell(pg);
        idris2rc2_poolCheckAlloc(c, k);
        return c;
#else
        return popCell(pg);
#endif
      }
      h->direct[k] = &dummyPage;
      pg->state = IDRIS2RC2_PAGE_FULL;
      listPush(&h->full[k], pg);
    }
    // The cells other threads released come before a new page is taken, so a
    // producer and a consumer do not grow the heap without bound.
    poolDrain(h);
    pg = takePage(h, k);
    h->direct[k] = pg;
  }
}

// ---- release ----

// Tells the owner that there is something to collect, once until it has looked.
static void queuePage(idris2rc2_Page *pg) {
  if (atomic_load(&pg->inPending) || atomic_exchange(&pg->inPending, 1)) return;
  for (;;) {
    idris2rc2_Heap *o = atomic_load(&pg->owner);
    idris2rc2_Page *top = atomic_load(&o->pending);
    if (top == POOL_DEAD) {
      // The owner has ended or is ending; whoever adopts the page collects
      // its thread_free. If the page has a new owner by now, queue it there.
      atomic_store(&pg->inPending, 0);
      if (atomic_load(&pg->owner) == o) return;
      if (atomic_exchange(&pg->inPending, 1)) return;
      continue;
    }
    pg->pendingNext = top;
    if (atomic_compare_exchange_strong(&o->pending, &top, pg)) return;
  }
}

// Cells this thread released to one page of another heap, linked but not yet
// on the page's thread_free: the cells of a list are mostly on one page, and a
// batch costs one compare-and-swap instead of one per cell. The cells still
// count in the page's `used`, so the page cannot be emptied under them.
static void remotePushChain(idris2rc2_Page *pg, void *head, void *tail) {
  void *old = atomic_load_explicit(&pg->thread_free, memory_order_relaxed);
  do {
    setNext(tail, old);
  } while (!atomic_compare_exchange_weak(&pg->thread_free, &old, head));
  queuePage(pg);
}

static void batchFlush(void) {
  if (!rb.pg) return;
  idris2rc2_Page *pg = rb.pg;
  rb.pg = NULL;
  remotePushChain(pg, rb.head, rb.tail);
}

static void remotePush(idris2rc2_Page *pg, void *c) {
  if (rb.ended) {
    remotePushChain(pg, c, c);
    return;
  }
  // A thread that only releases (a consumer) still gets a heap, for the hook
  // that flushes its batch when it ends.
  if (idris2rc2_tlHeap == &emptyHeap) idris2rc2_tlHeap = heapNew();
  if (rb.pg == pg) {
    setNext(c, rb.head);
    rb.head = c;
    if (++rb.n >= BATCH_MAX) batchFlush();
    return;
  }
  batchFlush();
  setNext(c, NULL);
  rb.pg = pg;
  rb.head = rb.tail = c;
  rb.n = 1;
}

void idris2rc2_poolAfter(idris2rc2_Heap *h, idris2rc2_Page *pg) { pageAfter(h, pg); }

void idris2rc2_poolFreeRemote(idris2rc2_Page *pg, void *c) { remotePush(pg, c); }

void idris2rc2_poolFree(void *c) {
#ifdef IDRIS2RC2_POOL_CHECK
  {
    idris2rc2_Page *pg = idris2rc2_poolPageOf(c);
    IDRIS2RC2_Header *hd = (IDRIS2RC2_Header *)c;
    IDRIS2RC2_VERIFY(!(hd->rc == 0xDEAD && hd->reserved == 0xDE), "cell pool: double release of %p", c);
    IDRIS2RC2_VERIFY(((char *)c - pg->base) % pg->cellSize == 0, "cell pool: %p is not a cell boundary", c);
    hd->rc = 0xDEAD;
    hd->reserved = 0xDE;
    fillBody(c, pg->cellSize);
  }
#endif
  idris2rc2_poolFreeInline(c);
}

void idris2rc2_poolPurge(void) {
  batchFlush();
  idris2rc2_Heap *h = idris2rc2_tlHeap;
  if (h != &emptyHeap) {
    poolDrain(h);
    for (int k = 0; k < IDRIS2RC2_POOL_CLASSES; k++) {
      idris2rc2_Page *pg = h->direct[k];
      if (pg != &dummyPage && pg->used == 0) {
        h->direct[k] = &dummyPage;
        emptyPush(h, pg);
      }
      for (idris2rc2_Page *p = h->full[k], *nx; p; p = nx) {
        nx = p->next;
        poolCollect(p);
        pageAfter(h, p);
      }
    }
    emptyTrim(h, 0, false);
  }
  // Pages of ended threads that only wait for their thread_free to be collected.
  sweepAbandoned();
}
