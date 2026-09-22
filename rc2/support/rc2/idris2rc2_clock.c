#include "clock.h"
#include "memory.h"
#include "util.h"

#include <errno.h>
#include <string.h>
#include <time.h>

#define NSEC_PER_SEC 1000000000ULL

// clock_gettime is POSIX and gives real nanosecond-resolution readings for
// every clock id used here (all guaranteed present on Linux since 2.6.28),
// unlike RefC's own clock.c which only has second resolution (time()) for
// UTC/monotonic and reuses that same crude clock for "monotonic" instead
// of a true monotonic source. We deliberately don't reproduce that
// crudeness -- see rc2/tests/refc-suite/clock/README notes on why its
// `expected` differs from upstream's.
static IDRIS2RC2_Value *clockTimeFrom(clockid_t id) {
  struct timespec ts;
  int rc = clock_gettime(id, &ts);
  IDRIS2RC2_VERIFY(rc == 0, "clock_gettime(%d) failed: %s", (int)id, strerror(errno));
  return idris2rc2_mkBits64((uint64_t)ts.tv_sec * NSEC_PER_SEC + (uint64_t)ts.tv_nsec);
}

IDRIS2RC2_Value *clockTimeUtc(void) { return clockTimeFrom(CLOCK_REALTIME); }

IDRIS2RC2_Value *clockTimeMonotonic(void) { return clockTimeFrom(CLOCK_MONOTONIC); }

IDRIS2RC2_Value *clockTimeProcess(void) { return clockTimeFrom(CLOCK_PROCESS_CPUTIME_ID); }

IDRIS2RC2_Value *clockTimeThread(void) { return clockTimeFrom(CLOCK_THREAD_CPUTIME_ID); }

// GC CPU/real time are optional clocks (System.Clock.isClockMandatory);
// rc2's runtime, like RefC's, doesn't track GC time at all, so both
// report "not implemented" via NULL -- osClockValid (below) then makes
// clockTime return Nothing for these.
IDRIS2RC2_Value *clockTimeGcCpu(void) { return NULL; }
IDRIS2RC2_Value *clockTimeGcReal(void) { return NULL; }

int clockValid(IDRIS2RC2_Value *clock) { return clock != NULL; }

uint64_t clockSecond(IDRIS2RC2_Value *clock) {
  return idris2rc2_to_u64(clock) / NSEC_PER_SEC;
}

uint64_t clockNanosecond(IDRIS2RC2_Value *clock) {
  return idris2rc2_to_u64(clock) % NSEC_PER_SEC;
}
