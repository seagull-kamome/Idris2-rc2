# Immediate `Int`, `Int64`, `Bits64` and `Integer`

Status: implemented (2026-09-27).

## Problem

A boxed value is an `IDRIS2RC2_Value *`. Types of at most 32 bits
(`Int32`, `Bits32`, `Char`, ...) already lived in the pointer word
itself. `Int`, `Int64` and `Bits64` were heap cells instead, except
for 0..99, which pointed at a static cache.

rc2 keeps an `Int` native (`int64_t`) inside a function whenever it
can. So this boxing only bit where a value has to be a `Value *`:
- a constructor field (a `List Int` cell);
- a closure's captured argument;
- polymorphic code, such as a comparator called through `apply`.

There it cost:
- an allocation per result;
- a refcount on every `dup`/`drop`;
- a pointer chase per read.

`sort`'s profile had the comparator touching two boxes' refcounts per
comparison (`TODO.md`, "`sort` against Chez").

## Representation

A value word with bit 0 set is an immediate; any other word is a heap
object or `NULL`. The tag says nothing more. Every read site knows the
value's type statically, and the type fixes the layout:

| Type | Immediate layout | Immediate range |
|---|---|---|
| `Int`, `Int64` | value << 1 \| 1 | [-2^62, 2^62) |
| `Bits64` | value << 1 \| 1 | [0, 2^63) |
| 32 bits or fewer (`Int32`, `Bits32`, `Char`, ...) | value << 32 \| 1 | all values (unchanged) |

A value outside those ranges is still a heap `IDRIS2RC2_Int64` or
`IDRIS2RC2_Bits64`. So the types keep their full 64-bit semantics:
- overflow wraps as before, since arithmetic is done on `int64_t` /
  `uint64_t` and only the result's representation is chosen;
- a foreign call still receives a full `int64_t` / `uint64_t`.

This is what Chez does too: its fixnums are about 61 bits, and larger
values become bignums, truncated back to 64 bits.

### Design history

The first version tagged with two bits: `01` for 32-bit scalars, `10`
for `Int`/`Int64`, `11` for `Bits64`, and payloads of 62 bits. Since
readers know the type, distinguishing the two 64-bit kinds, or 64-bit
from 32-bit, bought nothing. One tag bit widens both 64-bit ranges by a
bit. That matters for hashes: a 64-bit hash is below 2^62 a quarter of
the time, but below 2^63 half of the time. `missing-containers` went
from 6.51s to 6.33s.

Putting the 32-bit types into the same shifted layout was tried too. It
was not measurably slower: a `Char`-list benchmark took 5.73s against
5.71s. They still keep the upper-half layout, which a load can read
straight from memory without a shift.

## Runtime

- **`idris2rc2_mkInt64`, `idris2rc2_mkBits64`** return an immediate
  when the value fits, a heap box otherwise. The 0..99 static caches
  are gone.
- **`idris2rc2_to_i64`, `idris2rc2_to_u64`** test bit 0, then shift or
  read the box.
- **`dup`/`drop`** already skip every value with bit 0 set
  (`idris2rc2_is_unboxed`), so immediates cost nothing there.
- **`idris2rc2_isUnique`** is false for any immediate. The numeric
  primitives reuse a unique `Int64`/`Bits64` box for their result
  (`rop-reuse.md`), and must not write through an immediate.
- **`idris2rc2_extractInt`**, which gets a value of no known type,
  reads any immediate as a signed 63-bit value. So it is only for
  `Int` and `Int64`. An `RConstCase` over another integer type reads
  its scrutinee with that type's accessor (`extractIntExpr`).

## Code generation

`boxedConstExpr` (`Emit/Util.idr`) emits a literal in range as
`IDRIS2RC2_IMM_INT64(...)` / `IDRIS2RC2_IMM_BITS64(...)`. That is an
integer constant cast to a pointer, so it is also valid in a static
initializer, such as a folded constant constructor's field. A literal
out of range keeps its static box.

## `Integer`

`Integer` (and `Nat`, which compiles to it) uses the same immediate as
`Int64`: `value << 1 | 1`, range [-2^62, 2^62). It replaces the 0..99
static cache of `IDRIS2RC2_Integer` cells.

### Canonical form

An `Integer` in range is *always* immediate; a boxed mpz always holds a
value out of range. Every operation normalizes its result
(`idris2rc2_integerNormalize`, `idris2rc2_mkIntegerI64`). So:
- equality with an immediate is one word comparison, and an immediate
  never equals a boxed value;
- an `RConstCase` alt on an in-range `Integer` constant is a word
  comparison (`integerAltCond`). Out-of-range constants compare through
  GMP (`idris2rc2_integerEqualsLiteral`);
- an in-range literal is a C constant, so it needs no `let`
  (`bindOne`) and can sit in a folded constant constructor
  (`isConstLocalProof`).

### Operations

- Both operands immediate: `int64_t` arithmetic. Add and subtract
  cannot overflow 64 bits from 63-bit operands; multiply checks with
  `__builtin_mul_overflow`. `and`/`or`/`xor` of in-range values stay in
  range. `mod`, `div` (Euclidean) and the shifts follow GMP's
  semantics (`mpz_mod`, `mpz_fdiv_q_2exp`).
- Otherwise: the GMP slow path in `numeric.c`. An immediate operand is
  read as a read-only mpz through `idris2rc2_integerView`, which points
  `mpz_roinit_n` at one stack limb, so it never allocates. A unique
  boxed operand is reused for the result as before (`rop-reuse.md`).

GMP's own mixed functions (`mpz_add_ui`, `mpz_mul_si`, ...) would save
little over the view: the slow path is only reached with a value past
2^62, where GMP does the real work anyway.

### Foreign calls

- An `Integer` argument is passed as
  `idris2rc2_integerView(x, &(IDRIS2RC2_IntegerView){0})`. The compound
  literal lives until the end of the enclosing block, which contains
  the call. The callee must only read it, as before.
- An `Integer` result is still written into a fresh
  `IDRIS2RC2_Integer`'s mpz (GMP's `rop`-first convention), then
  normalized (`packCFType CFInteger`).
- `%export` copies an incoming mpz with `idris2rc2_mkIntegerFromMpz`,
  which normalizes too.

### Found along the way

- `cast {to = Double}` of a boxed `Integer` used `mpz_get_d`, which
  truncates: 2^63 - 1 became 2^63 - 1024, where Chez rounds to 2^63. It
  now rounds to nearest through the same helper as `String -> Double`.
- `RConstCase` over `Integer` read the scrutinee with `mpz_get_si`,
  which keeps only the low bits: 2^64 + 5 matched an alt `5`.

`Test108ImmediateInteger` covers every operation, cast and case on both
sides of ±2^62, ±2^63 and ±2^64, with negative operands and divisors,
against Chez.

### Results (2026-09-27)

Before: HEAD's generated C on HEAD's runtime. After: this change. Best
of 3; every program's output is unchanged.

| | before | after | Chez |
|---|---|---|---|
| `Nat` fib 30, Collatz to 300k, `Nat` list of 2M | 10.65s | 1.70s | 1.94s |
| `sort`, 1M `Int`s | 1.12s | 1.13s | |
| map/filter | 3.32s | 3.31s | |
| closures | 1.87s | 1.82s | |
| `Char` list | 5.86s | 5.90s | |
| `idris2-missing-containers` | 5.63s | 5.67s | |

The programs without `Integer` stay within noise.

## Tests

`Test105ImmediateInts` puts `Int`, `Int64` and `Bits64` values into
lists, so that they are stored in their boxed form, on both sides of
each boundary:
- ±2^61 and ±2^62 for `Int` and `Int64`;
- 2^62 and 2^63 for `Bits64`;
- the 64-bit extremes.

It runs arithmetic, shifts, bit operations, comparisons and casts on
each, and compares against Chez's output.

It also found an older bug: `cast {to = Bits64}` of a `String` used
`atoll`, which stops at `INT64_MAX`. It now uses `strtoull`.

## Results (2026-09-27)

Measured on the first, two-bit version. Before: the previous
generated C on the previous runtime. After: C generated by that
version on its runtime. The one-bit version is a few percent faster
again on `sort` and `missing-containers` (see "Design history"). Best of 3; every program's
output is unchanged.

| | before | after |
|---|---|---|
| `sort`, 1M `Int`s | 2.44s | 1.59s (-35%) |
| map/filter, 300k x 50 | 6.64s | 3.36s (-49%) |
| closures, 1M x 20 | 2.55s | 1.86s (-27%) |
| BenchKnownCon | 0.54s | 0.27s |
| BenchPushCon | 0.22s | 0.08s |
| BenchArityRaise | 0.59s | 0.41s |
| `idris2-missing-containers` | 6.49s | 6.54s |

`missing-containers` is mostly strings and 64-bit hashes. A hash is
spread over the whole `Bits64` range, so only about a quarter of them
fall below 2^62 and become immediate.
