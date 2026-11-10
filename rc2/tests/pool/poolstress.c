// Stress test of the cell pool alone (rc2/doc/small-object-allocator.md):
// release across threads, a ring of threads that all allocate and release,
// threads that end with live cells, local churn, and the return of memory.
// Exits 1 on the first corrupted cell or unmet bound.

#include "idris2rc2_pool.h"

#if defined(__SANITIZE_THREAD__)
#define UNDER_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define UNDER_TSAN 1
#endif
#endif

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned long long errors;
static void fail(char const *what) {
  fprintf(stderr, "FAIL %s\n", what);
  __atomic_add_fetch(&errors, 1, __ATOMIC_RELAXED);
}

// A cell: word 0 is the header (untouched here), the rest is a pattern.
static size_t words(int k) { return (IDRIS2RC2_POOL_MIN_CELL + 8 * (size_t)k) / 8; }
static void fill(void *c, int k, uint64_t seq) {
  uint64_t *w = c;
  w[0] = 0; // the header of a cell the allocator hands out is the caller's to set
  for (size_t i = 2; i < words(k); i++) w[i] = seq + i;
}
static void check(void *c, int k, uint64_t seq) {
  uint64_t *w = c;
  for (size_t i = 2; i < words(k); i++)
    if (w[i] != seq + i) {
      fail("cell content changed");
      return;
    }
}

typedef struct { void *c; int k; uint64_t seq; } Item;
#define QCAP 4096
typedef struct {
  Item buf[QCAP];
  int head, tail, n, done;
  pthread_mutex_t m;
  pthread_cond_t notEmpty, notFull;
} Queue;
static void qinit(Queue *q) { memset(q, 0, sizeof *q); pthread_mutex_init(&q->m, 0); pthread_cond_init(&q->notEmpty, 0); pthread_cond_init(&q->notFull, 0); }
static void qput(Queue *q, Item it) {
  pthread_mutex_lock(&q->m);
  while (q->n == QCAP) pthread_cond_wait(&q->notFull, &q->m);
  q->buf[q->tail] = it; q->tail = (q->tail + 1) % QCAP; q->n++;
  pthread_cond_signal(&q->notEmpty);
  pthread_mutex_unlock(&q->m);
}
static int qtryput(Queue *q, Item it) {
  pthread_mutex_lock(&q->m);
  if (q->n == QCAP) { pthread_mutex_unlock(&q->m); return 0; }
  q->buf[q->tail] = it; q->tail = (q->tail + 1) % QCAP; q->n++;
  pthread_mutex_unlock(&q->m);
  return 1;
}
static int qget(Queue *q, Item *it, int wait) {
  pthread_mutex_lock(&q->m);
  while (q->n == 0 && !q->done && wait) pthread_cond_wait(&q->notEmpty, &q->m);
  if (q->n == 0) { pthread_mutex_unlock(&q->m); return 0; }
  *it = q->buf[q->head]; q->head = (q->head + 1) % QCAP; q->n--;
  pthread_cond_signal(&q->notFull);
  pthread_mutex_unlock(&q->m);
  return 1;
}
static void qclose(Queue *q) { pthread_mutex_lock(&q->m); q->done = 1; pthread_cond_broadcast(&q->notEmpty); pthread_mutex_unlock(&q->m); }

static unsigned next(unsigned s) { return s * 1103515245u + 12345u; }
static int pickClass(unsigned s) { return (s >> 4) % 3 ? (int)((s >> 12) % 3) : (int)((s >> 8) % IDRIS2RC2_POOL_CLASSES); }

// ---- 1. producers and consumers ----

static Queue pc;
static long perProducer = 600000;
static void *producer(void *arg) {
  uint64_t base = (uint64_t)(uintptr_t)arg << 40;
  unsigned s = (unsigned)(uintptr_t)arg * 7919u + 1;
  for (long i = 0; i < perProducer; i++) {
    s = next(s);
    int k = pickClass(s);
    void *c = idris2rc2_poolAlloc(k);
    fill(c, k, base + i);
    if ((s >> 20) % 4 == 0) { check(c, k, base + i); idris2rc2_poolFree(c); continue; }
    qput(&pc, (Item){c, k, base + i});
  }
  return NULL;
}
static void *consumer(void *arg) {
  (void)arg;
  Item it;
  while (qget(&pc, &it, 1)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); }
  return NULL;
}

// ---- 2. a ring: every thread allocates, passes to the next, releases what it gets ----

#define RING 4
static Queue ring[RING];
static int ringDone;
static void *ringThread(void *arg) {
  int me = (int)(uintptr_t)arg, nxt = (me + 1) % RING;
  unsigned s = (unsigned)me * 104729u + 3;
  uint64_t base = (uint64_t)(me + 1) << 40;
  long sent = 0, total = perProducer / 2;
  Item it;
  while (sent < total) {
    while (qget(&ring[me], &it, 0)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); }
    s = next(s);
    int k = pickClass(s);
    void *c = idris2rc2_poolAlloc(k);
    fill(c, k, base + sent);
    Item out = {c, k, base + sent};
    // A full queue of the next thread must not stop this one from receiving.
    while (!qtryput(&ring[nxt], out))
      while (qget(&ring[me], &it, 0)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); }
    sent++;
  }
  __atomic_add_fetch(&ringDone, 1, __ATOMIC_SEQ_CST);
  // Keep receiving until every thread has sent everything.
  while (__atomic_load_n(&ringDone, __ATOMIC_SEQ_CST) < RING)
    while (qget(&ring[me], &it, 0)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); }
  return NULL;
}

// ---- 2b. producers that end at once, one consumer that stays ----

static Queue dq;
static void *dyingProducer(void *arg) {
  uint64_t base = (uint64_t)(uintptr_t)arg << 32;
  for (int i = 0; i < 500; i++) {
    int k = i % IDRIS2RC2_POOL_CLASSES;
    void *c = idris2rc2_poolAlloc(k);
    fill(c, k, base + i);
    qput(&dq, (Item){c, k, base + i});
  }
  return NULL;
}
static void *stayingConsumer(void *arg) {
  (void)arg;
  Item it;
  while (qget(&dq, &it, 1)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); }
  return NULL;
}

// ---- 3. threads that end with live cells ----

static void *shortLived(void *arg) {
  void **out = arg;
  for (int i = 0; i < 1000; i++) { int k = i % IDRIS2RC2_POOL_CLASSES; void *c = idris2rc2_poolAlloc(k); fill(c, k, i); out[i] = c; }
  return NULL;
}

static size_t rssKb(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  unsigned long a = 0, b = 0;
  if (f) { if (fscanf(f, "%lu %lu", &a, &b) != 2) b = 0; fclose(f); }
  return b * (size_t)sysconf(_SC_PAGESIZE) / 1024;
}

int main(int argc, char **argv) {
  if (argc > 1) perProducer = atol(argv[1]);

  pthread_t t[8];
  qinit(&pc);
  for (int i = 0; i < 3; i++) pthread_create(&t[i], 0, producer, (void *)(uintptr_t)(i + 1));
  for (int i = 3; i < 6; i++) pthread_create(&t[i], 0, consumer, 0);
  for (int i = 0; i < 3; i++) pthread_join(t[i], 0);
  qclose(&pc);
  for (int i = 3; i < 6; i++) pthread_join(t[i], 0);
  printf("producers and consumers: errors=%llu\n", errors);

  for (int i = 0; i < RING; i++) qinit(&ring[i]);
  for (int i = 0; i < RING; i++) pthread_create(&t[i], 0, ringThread, (void *)(uintptr_t)i);
  for (int i = 0; i < RING; i++) pthread_join(t[i], 0);
  for (int i = 0; i < RING; i++) { Item it; while (qget(&ring[i], &it, 0)) { check(it.c, it.k, it.seq); idris2rc2_poolFree(it.c); } }
  printf("ring: errors=%llu\n", errors);

  qinit(&dq);
  idris2rc2_poolResetPeak();
  size_t beforeD = idris2rc2_poolPagesInUse();
  pthread_t sc;
  pthread_create(&sc, 0, stayingConsumer, 0);
  for (int r = 0; r < 400; r++) {
    pthread_t th;
    pthread_create(&th, 0, dyingProducer, (void *)(uintptr_t)(r + 1));
    pthread_join(th, 0);
  }
  qclose(&dq);
  pthread_join(sc, 0);
  size_t dying = idris2rc2_poolPagesPeak() - beforeD;
  printf("dying producers, one consumer: errors=%llu, pages in use at the peak: +%zu\n", errors, dying);
  if (dying > 128) fail("pages of dying producers are not reused");

  idris2rc2_poolResetPeak();
  size_t before = idris2rc2_poolPagesInUse();
  static void *cells[1000];
  for (int r = 0; r < 300; r++) {
    pthread_t th;
    pthread_create(&th, 0, shortLived, cells);
    pthread_join(th, 0);
    for (int i = 0; i < 1000; i++) { check(cells[i], i % IDRIS2RC2_POOL_CLASSES, i); idris2rc2_poolFree(cells[i]); }
  }
  size_t churn = idris2rc2_poolPagesPeak() - before;
  printf("threads that end: errors=%llu, pages in use at the peak: +%zu\n", errors, churn);
  // Without adopting and sweeping, each of the 300 threads would take a page for each of its 15 classes.
  if (churn > 64) fail("pages of ended threads are not reused");

  enum { N = 2000000 };
  typedef struct { void *c; int k; int seq; } Cell;
  Cell *a = malloc(N * sizeof(Cell));
  unsigned s = 1;
  for (int round = 0; round < 3; round++) {
    for (int i = 0; i < N; i++) { int k = i % 5; a[i].c = idris2rc2_poolAlloc(k); a[i].k = k; a[i].seq = i; fill(a[i].c, k, i); }
    for (int i = N - 1; i > 0; i--) { s = next(s); int j = s % (i + 1); Cell x = a[i]; a[i] = a[j]; a[j] = x; }
    for (int i = 0; i < N; i++) { check(a[i].c, a[i].k, a[i].seq); idris2rc2_poolFree(a[i].c); }
  }
  printf("local churn: errors=%llu\n", errors);
  free(a);

  // Return of memory: a large heap is built and released; after a purge the resident size falls.
  enum { M = 8000000 };
  void **big = malloc(M * sizeof(void *));
  for (int i = 0; i < M; i++) { big[i] = idris2rc2_poolAlloc(1); *(uint64_t *)big[i] = 0; }
  size_t peak = rssKb();
  for (int i = 0; i < M; i++) idris2rc2_poolFree(big[i]);
  free(big);
  idris2rc2_poolPurge();
  size_t after = rssKb();
  printf("return of memory: peak %zu kB, after purge %zu kB\n", peak, after);
#ifndef UNDER_TSAN // the shadow memory of ThreadSanitizer is resident too
  if (peak < 100000) fail("the resident size could not be read, or the heap did not grow");
  if (after > peak / 2) fail("resident size did not fall after the purge");
#endif

  return errors ? 1 : 0;
}
