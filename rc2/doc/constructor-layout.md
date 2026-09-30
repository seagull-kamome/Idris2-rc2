# Constructor, closure, and String cell layout

## Constructors

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

## Closures

`IDRIS2RC2_Closure` had the same gap. `fn` sat right after the header,
and `arity`/`filled` (one byte each) came after it:

| | Before | After |
|---|---|---|
| header | 0..4 | 0..4 |
| `arity`, `filled` | 16..18 | 4..6 |
| `fn` | 8..16 | 8..16 |
| `args` | 24.. | 16.. |

A heap closure always has room for its full arity, so it takes
16 + 8·arity bytes, 8 fewer than before. `IDRIS2RC2_ConstClosure`, the
static form of a closure with nothing filled yet, has the same leading
fields. Its initializer (`boxedConstClosureExpr`) now names them, so it
no longer depends on their order.

Whether the 8 bytes pay off depends on the allocator. glibc hands out
chunks in 16-byte steps. With 8 bytes of chunk overhead, an even arity
stays in the same chunk size, and only an odd arity moves down one.
Measured on building and folding 1M closures, 20 times
(2026-09-26, same generated C linked against either runtime):

| Closure | Allocator | Before | After |
|---|---|---|---|
| arity 3 | glibc | 3.89s, 128MB | 3.71s, 112MB |
| arity 3 | mimalloc | 3.46s, 134MB | 3.15s, 102MB |
| arity 2 | glibc | 3.70s, 112MB | 3.73s, 112MB |

The arity-2 run allocates 8% fewer bytes (valgrind), but neither its time
nor its RSS moved, under glibc or mimalloc. `sort` is unaffected,
since its comparator closure is built once.

## Strings

```c
typedef struct {
  IDRIS2RC2_Header header;
  uint32_t len; // byte length of str's content, excluding the terminator
  char *str;    // NUL-terminated, UTF-8 bytes; may contain embedded NUL
                // bytes; indexing is byte-based
} IDRIS2RC2_String;
```

Also 16 bytes (`_Static_assert`-checked in `idris2rc2_datatypes.h`):
`len` sits in the same 4 bytes of header-alignment padding the
Constructor/Closure layouts above reuse for their own extra fields,
right before `str`. `len` is the string's byte length, not its
codepoint count (see README.md's "Deliberate differences from upstream
RefC" for why `String` is codepoint-indexed at the API level while
`len` itself counts bytes) -- and, unlike a plain `strlen`, it lets a
`String` hold an embedded NUL byte: every primitive that needs the
string's extent (comparison, `++`, `pack`/`unpack`, pattern-matching a
literal) reads `len`, not the terminator. `str` itself stays
NUL-terminated regardless, purely so it can still be handed to C as an
ordinary `char *` -- crossing that boundary (an FFI argument, a
`%export`ed return, a `String`-to-number cast) still cuts at the first
embedded NUL, an accepted limitation covered in
`rc2/doc/fastpack-fix.md` and README.md.

A result whose byte length would overflow `len`'s own `uint32_t`
(over 4 GiB) aborts at the point it would be constructed
(`idris2rc2_checkedStrLen`, `idris2rc2_memory.h`) rather than silently
wrapping into a corrupt, too-short `len`.

## Pitfall: the runtime `Makefile`

`rc2/support/rc2/Makefile` used to have no header dependencies. After
the layout change, `make` rebuilt only the `.c` files that had changed
themselves. `idris2rc2_strings.o` kept the old layout and wrote past
every cell it allocated (`malloc(): corrupted top size`, 30 failures in
`verify.sh`). Every object now depends on every header.
