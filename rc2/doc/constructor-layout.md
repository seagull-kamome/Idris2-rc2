# Constructor cell layout (`IDRIS2RC2_Constructor`)

## Layout

| Bytes | Field |
|---|---|
| 0..4 | header (refcount, value tag, reserved) |
| 4..6 | arity (`uint16_t`) |
| 6..8 | tag (`int16_t`, -1 if none) |
| 8.. | `args[arity]` |
| 8 + 8·arity | name, **only if tag is -1** |

A cons cell is 24 bytes. `idris2rc2_newConstructor` allocates the name
slot only when `tag < 0`. `idris2rc2_conName` / `idris2rc2_setConName`
read and write it as `args[arity]`.

A constant constructor (`RCConstCon`, `doc/const-con-fold.md`) gets the
same layout: a tagged one uses `IDRIS2RC2_ConstConstructor<n>`, an
untagged one an anonymous struct with one extra slot for the name.

## Why

Until 2026-09 the layout was:

| Bytes | Field |
|---|---|
| 0..4 | header |
| 4..8 | arity (`int32_t`) |
| 8..12 | tag (`int32_t`) |
| 12..16 | padding |
| 16..24 | name |
| 24.. | args |

A cons cell was 40 bytes, a 48-byte glibc chunk; Chez's is 16. `name` is
read only by a `strcmp` match on an untagged constructor, and for
`%World`. Every tagged constructor (lists, `Maybe`, tuples, records)
carried it for nothing.

The header is 4 bytes, but `args` needs 8-byte alignment, so 4 bytes
after it were padding anyway. Two 16-bit fields fill exactly that gap.
The gap is filled by ordering the fields, not by
`__attribute__((packed))`, which would buy nothing more:
- A packed struct gives the `_Atomic` refcount no alignment guarantee.
- A boxed `Int64`/`Double` would shrink from 16 to 12 bytes, but the
  allocator hands out 16 anyway. The payload would just be misaligned.

Moving `name` to 8 while keeping it in every cell would give 32 bytes,
still a 48-byte glibc chunk. So the name moves behind the fields, and
only into untagged cells.

## Limits

Arity is at most 65535 and a tag at most 32767. The emitter checks both
(`checkConLayout` in `Emit/Util.idr`) and fails the compile rather
than truncating. No real data type comes close.

## Results (2026-09-26)

`Data.List.sort` of 1M `Int`s (`TODO.md`, "`sort` against Chez"):

| | Before | After |
|---|---|---|
| time | 3.237s | 3.117s (-3.7%) |
| time, mimalloc | 2.457s | 2.400s |
| max RSS | 81.4MB | 65.8MB (-19%) |
| cache-misses | 118M | 104M (-12%) |
| L1-dcache-load-misses | 85.7M | 73.6M |

Instruction counts are unchanged, so the time saved is all memory
traffic. The gain is modest. The stalls loading list cells come mostly
from cells scattered across the heap, and from each boxed `Int` being
one more pointer to chase, not from the cells' size.

## Pitfall: the runtime `Makefile`

`rc2/support/rc2/Makefile` used to have no header dependencies. After
the layout change, `make` rebuilt only the `.c` files that had changed
themselves. `idris2rc2_strings.o` kept the old layout and wrote past
every cell it allocated (`malloc(): corrupted top size`, 30 failures in
`verify.sh`). Every object now depends on every header.
