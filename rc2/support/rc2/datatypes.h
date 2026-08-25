#pragma once

// Value representation for the rc2 backend runtime.
//
// Every heap value starts with a small header carrying an atomic
// reference count and a type tag. Small fixed-width integers/Char are
// represented unboxed, packed into the pointer itself (tagged pointers),
// exactly like a plain pointer with its low bit set so it can never be
// confused with a real (word-aligned) heap pointer.
//
// This design targets 64-bit (LP64) platforms only: an unboxed payload of
// up to 32 bits is packed into the upper bits of the pointer word, leaving
// the low 2 bits free for tagging.

#include <gmp.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IDRIS2RC2_TAG_NONE 0
#define IDRIS2RC2_TAG_BITS32 3
#define IDRIS2RC2_TAG_BITS64 4
#define IDRIS2RC2_TAG_INT32 7
#define IDRIS2RC2_TAG_INT64 8
#define IDRIS2RC2_TAG_INTEGER 9
#define IDRIS2RC2_TAG_DOUBLE 10
#define IDRIS2RC2_TAG_STRING 12
#define IDRIS2RC2_TAG_CLOSURE 15
#define IDRIS2RC2_TAG_CONSTRUCTOR 17
#define IDRIS2RC2_TAG_IOREF 20
#define IDRIS2RC2_TAG_ARRAY 21
#define IDRIS2RC2_TAG_POINTER 22
#define IDRIS2RC2_TAG_GCPOINTER 23
#define IDRIS2RC2_TAG_BUFFER 24
#define IDRIS2RC2_TAG_MUTEX 25
#define IDRIS2RC2_TAG_CONDITION 26
#define IDRIS2RC2_TAG_SEMAPHORE 27
#define IDRIS2RC2_TAG_BARRIER 28
#define IDRIS2RC2_TAG_JOINHANDLE 29
#define IDRIS2RC2_TAG_CHANNEL 30

typedef struct {
  // Values that reach the maximum reference count are treated as immortal
  // (never freed). This also covers statically-allocated values.
#define IDRIS2RC2_REFCOUNT_MAX UINT16_MAX
  _Atomic uint16_t refCount;
  uint8_t tag;
  uint8_t reserved;
} IDRIS2RC2_Header;

#define IDRIS2RC2_STOCKVAL(t) {IDRIS2RC2_REFCOUNT_MAX, (t), 0}

typedef struct {
  IDRIS2RC2_Header header;
  // Payload follows, depending on `header.tag` (see IDRIS2RC2_* structs below).
} IDRIS2RC2_Value;

// bit0 set => unboxed scalar payload packed into the pointer word itself.
#define idris2rc2_is_unboxed(p) ((uintptr_t)(p)&3)
#define idris2rc2_unbox_shift 32

#define idris2rc2_to_i64(p) (((IDRIS2RC2_Int64 *)(p))->v)
#define idris2rc2_to_u64(p) (((IDRIS2RC2_Bits64 *)(p))->v)
#define idris2rc2_to_u32(p) ((uint32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i32(p) ((int32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_u16(p) ((uint16_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i16(p) ((int16_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_u8(p) ((uint8_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i8(p) ((int8_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_char(p) ((uint32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_bool(p) (idris2rc2_to_i8(p))
#define idris2rc2_to_double(p) (((IDRIS2RC2_Double *)(p))->v)

typedef struct {
  IDRIS2RC2_Header header;
  uint32_t v;
} IDRIS2RC2_Bits32;
typedef struct {
  IDRIS2RC2_Header header;
  uint64_t v;
} IDRIS2RC2_Bits64;
typedef struct {
  IDRIS2RC2_Header header;
  int32_t v;
} IDRIS2RC2_Int32;
typedef struct {
  IDRIS2RC2_Header header;
  int64_t v;
} IDRIS2RC2_Int64;
typedef struct {
  IDRIS2RC2_Header header;
  mpz_t v;
} IDRIS2RC2_Integer;
typedef struct {
  IDRIS2RC2_Header header;
  double v;
} IDRIS2RC2_Double;
typedef struct {
  IDRIS2RC2_Header header;
  char *str; // NUL-terminated, UTF-8 bytes; indexing is byte-based
} IDRIS2RC2_String;

typedef struct {
  IDRIS2RC2_Header header;
  int32_t arity;
  int32_t tag; // -1 if this constructor is identified by name instead
  char const *name;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Constructor;

// A zero-argument, tagged data constructor other than Nil/Nothing/Z/
// MkUnit (those four are represented as a bare NULL instead, matched by
// NULL-vs-non-NULL -- see Compiler.RC2.Emit's RCon/RConCase) has no
// fields to store, so it's represented the same way as any other small
// unboxed scalar: its own tag packed into a tagged pointer (see
// RCEmptyCon in Compiler.RC2.RCExp), never a real IDRIS2RC2_Constructor
// allocation. A scrutinee of such a type can therefore be *either* a
// tagged pointer or a real heap IDRIS2RC2_Constructor* depending on
// which alternative it happens to hold at runtime, so any tag-based
// dispatch (Compiler.RC2.Emit's RConCase) must check is_unboxed first
// rather than always dereferencing as a heap object.
#define idris2rc2_conTag(p) (idris2rc2_is_unboxed(p) ? (int32_t)idris2rc2_to_u32(p) : ((IDRIS2RC2_Constructor *)(p))->tag)

typedef struct {
  IDRIS2RC2_Header header;
  void *fn; // cast to the right arity's function pointer type to call
  uint8_t arity;
  uint8_t filled;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Closure;

// `lock` guards `v` itself (the swap-and-drop-old sequence in
// writeIORef/readIORef, ioprims.c) -- see util.h's idris2rc2_spin_lock
// doc comment for why a bare atomic load+dup on `v` isn't enough.
typedef struct {
  IDRIS2RC2_Header header;
  atomic_flag lock;
  IDRIS2RC2_Value *v;
} IDRIS2RC2_IORef;

typedef struct {
  IDRIS2RC2_Header header;
  void *p;
} IDRIS2RC2_Pointer;

typedef struct {
  IDRIS2RC2_Header header;
  IDRIS2RC2_Pointer *p;
  IDRIS2RC2_Closure *onCollect;
} IDRIS2RC2_GCPointer;

// `lock` guards `items` the same way IDRIS2RC2_IORef's own lock guards
// `v` -- one lock for the whole array (coarse-grained, matching a
// single IORef's own granularity), not one per element.
typedef struct {
  IDRIS2RC2_Header header;
  atomic_flag lock;
  int capacity;
  IDRIS2RC2_Value **items;
} IDRIS2RC2_Array;

// Wraps a raw malloc'd buffer.c allocation (see IDRIS2RC2_RawBuffer in
// buffer.h) so it participates in refcounting like any other heap value;
// freed via idris2rc2_teardown's IDRIS2RC2_TAG_BUFFER case (memory.c).
typedef struct {
  IDRIS2RC2_Header header;
  void *buf;
} IDRIS2RC2_Buffer;

// Mutex/Condition back System.Concurrency.RC2 (libs/rc2base) -- upstream
// System.Concurrency.idr's `Mutex`/`Condition` are `[external]`, which
// rc2 marshals as CFUser (an unconstrained IDRIS2RC2_Value* passthrough,
// see Compiler.RC2.EmitUtil's packCFType/extractValue for CFUser), so any
// value shaped like this is a valid one. The pthread object is embedded
// directly (one allocation, no extra indirection through
// IDRIS2RC2_Pointer) and destroyed by idris2rc2_teardown once refcount
// reaches zero, same as IDRIS2RC2_TAG_BUFFER's free(buf).
typedef struct {
  IDRIS2RC2_Header header;
  pthread_mutex_t mutex;
} IDRIS2RC2_Mutex;

typedef struct {
  IDRIS2RC2_Header header;
  pthread_cond_t cond;
} IDRIS2RC2_Condition;

typedef struct {
  IDRIS2RC2_Header header;
  sem_t sem;
} IDRIS2RC2_Semaphore;

typedef struct {
  IDRIS2RC2_Header header;
  pthread_barrier_t barrier;
} IDRIS2RC2_Barrier;

// Backs System.Concurrency.RC2's rc2-specific joinable fork (forkJoin/
// join) -- upstream System.Concurrency.idr's ThreadID/threadWait can't
// join anything from a C backend (threadWait is scheme-only), so this is
// a new type, not a %foreign_impl patch onto an existing one. `joined`
// guards idris2rc2_teardown: pthread_detach only if join was never
// called (so a dropped-but-never-joined thread isn't leaked as a
// zombie); once idris2rc2_join has pthread_join'd, `tid` is no longer a
// valid identifier and must not be touched again.
typedef struct {
  IDRIS2RC2_Header header;
  pthread_t tid;
  bool joined;
} IDRIS2RC2_JoinHandle;

// Backs System.Concurrency.RC2's Channel: an unbounded FIFO queue of
// owned IDRIS2RC2_Value* nodes, guarded by an embedded mutex/condition
// pair (put appends+signals, get blocks while empty then pops). Torn
// down by idris2rc2_teardown, which must walk any still-queued nodes,
// dropping each one's value, before destroying the mutex/cond -- a
// channel dropped with pending, never-received messages must not leak
// them.
typedef struct idris2rc2_ChannelNode {
  struct idris2rc2_ChannelNode *next;
  IDRIS2RC2_Value *value;
} idris2rc2_ChannelNode;

typedef struct {
  IDRIS2RC2_Header header;
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  idris2rc2_ChannelNode *head;
  idris2rc2_ChannelNode *tail;
} IDRIS2RC2_Channel;
