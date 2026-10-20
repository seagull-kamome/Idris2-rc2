# Native `Ptr` / `AnyPtr` (design)

Status: design, not implemented (2026-10-20). Supersedes the "Investigated:
native (unboxed) `Ptr`/`CFPtr`" section of `c-struct-support.md`, whose
objections are answered below.

## Problem

`Ptr t`, `AnyPtr` (`CFPtr`) and struct pointers (`CFStruct`) are always
boxed: `packCFType` allocates an `IDRIS2RC2_Pointer` per value, and every
`dup`/`drop` touches its refcount. The wrapper protects nothing: teardown
never frees the payload (`memory.c`, `TAG_POINTER`), so the refcount tracks
no resource. `getField`, `setField` and each `%foreign` returning a pointer
pay the allocation.

## Decisions

### 1. Representation inside a boxed value: an immediate, like `Bits64`

A pointer `raw` in `[0, 2^63)` is the word `raw << 1 | 1`; anything else is
a heap box (the existing `Bits64` box). `dup`/`drop` skip it through
`idris2rc2_is_unboxed`. Every address is representable, so odd or high-bit
addresses keep their meaning; ordinary user-space addresses (x86-64,
aarch64) are always immediate. `IDRIS2RC2_Pointer` and `TAG_POINTER` go away.

### 2. Native representation: a pointer to an opaque struct

```c
typedef struct IDRIS2RC2_Raw IDRIS2RC2_Raw;   /* never defined */
```

A native pointer is an `IDRIS2RC2_Raw *`, not an integer:
- an integer round trip (`(void *)(uintptr_t)x`) loses provenance, which
  weakens alias analysis wherever it crosses a worker argument, a return
  value or a loop variable;
- `void *` converts implicitly to and from any pointer, so mixing it with an
  `IDRIS2RC2_Value *` is silently accepted. `IDRIS2RC2_Raw *` and
  `IDRIS2RC2_Value *` are incompatible, and the generated C is built with
  `-Werror=incompatible-pointer-types`;
- object pointers still convert implicitly to and from `void *`, so a
  `%foreign` argument of any C pointer type needs no cast;
- the type is incomplete, so nothing in generated code can dereference it.

Conversion to and from the boxed word (`mkPtr` / `toPtr`, going through
`uintptr_t`) happens only where a pointer is boxed or unboxed.

### 3. `Rep` gets its own native type

`RNative`/`RInlineNative`/`RRet` are typed over upstream's `PrimType`, which
has no pointer case. They become typed over an rc2 type:

```idris
data NatTy = NPrim PrimType | NPtr
```

`nativeCType NPtr` is `IDRIS2RC2_Raw *`. `NPtr` has no arithmetic, only
equality and a null test, and counts as `alwaysUnboxed` (no dup/drop).
`cfTypeNative` maps `CFPtr` and `CFStruct` to `NPtr`.

### 4. Excluded: `GCPtr` / `GCAnyPtr` (`CFGCPtr`)

Its `onCollect` callback depends on the refcount of the boxed object. It
stays a heap `IDRIS2RC2_GCPointer`; its inner `p` becomes a boxed pointer
word as in (1), and `extractValue` reads it through `toPtr`.

## Answers to the earlier objections

| Objection | Answer |
|---|---|
| `Rep` has no pointer case; every `Rep` match changes | `NatTy`, introduced first as a behaviour-preserving refactoring |
| `CFGCPtr` needs the refcount | excluded (4) |
| lost reachability tracking | there was none to lose: the payload is never freed; only IR visibility is lost |

## Cost

`RNative`/`RInlineNative` appear about 150 times in 9 files (`Emit` 47,
`DualABI` 28, `Loop` 19, `Emit/Util` 15, `LateInline` 13, `RC` 11, ...).
Most only ask "is it native"; only the sites that read the `PrimType` change.
Existing `CExpr` declarations need no change: 1178 were checked, none does
pointer arithmetic on an unmodified `$n` pointer argument (the one `+` chain,
`Test118FFI/FFICExpr.idr:101`, is integer).

## Steps

1. Measure: `mkPointer` allocations and time on the termui Demo and the
   rc2base tests; compare hand-edited C using `uint64_t` against
   `IDRIS2RC2_Raw *`. If the gain is small, stop.
2. Refactoring: introduce `NatTy` with only `NPrim`; no output change.
3. Representation: immediate pointers in the runtime, `packCFType` /
   `extractValue`, `onCollect`, `%export` wrappers. Still boxed in the IR.
4. Enable `NPtr`: `cfTypeNative`, FFI workers, `RStructGet`/`RStructSet`,
   `-Werror=incompatible-pointer-types`.
5. Tests: odd address, address with the top bit set, NULL, `GCPtr`
   `onCollect` exactly once, plus `Test24CStructSupport`, the Posix tests,
   TestCurl and the termui tests.

## Open points

- Does a pointer parameter that is only passed on to a `%foreign` call
  become native? `paramEligibility` decides; if it does not, the gain is
  limited to the FFI boundary.
- `LEAK_SENSITIVE_TESTS` count allocations; their expectations may change.
