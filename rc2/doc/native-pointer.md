# Native `Ptr` / `AnyPtr` (design)

Status: implemented (2026-10-20), see "Result". Supersedes the "Investigated:
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
data NativeTy = TPrim PrimType | TPtr
```

`nativeCType TPtr` is `IDRIS2RC2_Raw *`. `TPtr` has no arithmetic, only
equality and a null test, and counts as `alwaysUnboxed` (no dup/drop).
`cfTypeNative` maps `CFPtr` and `CFStruct` to `TPtr`.

### 4. Excluded: `GCPtr` / `GCAnyPtr` (`CFGCPtr`)

Its `onCollect` callback depends on the refcount of the boxed object. It
stays a heap `IDRIS2RC2_GCPointer`; its inner `p` becomes a boxed pointer
word as in (1), and `extractValue` reads it through `toPtr`.

## Answers to the earlier objections

| Objection | Answer |
|---|---|
| `Rep` has no pointer case; every `Rep` match changes | `NativeTy`, introduced first as a behaviour-preserving refactoring |
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
2. Refactoring: introduce `NativeTy` with only `TPrim`; no output change.
3. Representation: immediate pointers in the runtime, `packCFType` /
   `extractValue`, `onCollect`, `%export` wrappers. Still boxed in the IR.
4. Enable `TPtr`: `cfTypeNative`, FFI workers, `RStructGet`/`RStructSet`,
   `-Werror=incompatible-pointer-types`.
5. Tests: odd address, address with the top bit set, NULL, `GCPtr`
   `onCollect` exactly once, plus `Test24CStructSupport`, the Posix tests,
   TestCurl and the termui tests.

## Open points

- Does a pointer parameter that is only passed on to a `%foreign` call
  become native? `paramEligibility` decides; if it does not, the gain is
  limited to the FFI boundary.
- `LEAK_SENSITIVE_TESTS` count allocations; their expectations may change.

## Result (2026-10-20)

Implemented: pointers are immediate boxed words (decision 1). `mkPointer`,
`IDRIS2RC2_Pointer` and `IDRIS2RC2_TAG_POINTER` are gone; `idris2rc2_mkPtr`
is an inline function whose fast path is the immediate, `idris2rc2_toPtr`
reads it back. `Test119FFINoRefc/NativePtr.idr` covers 0, odd addresses, the
top bit, NULL and `onCollectAny`.

`BenchPtr.idr` (200M iterations, each producing a pointer with `+ offset`
and reading through it; the loop variables are native, the pointer crosses
the FFI calls boxed):

| | time |
|---|---|
| before (`mkPointer`, one allocation and refcount per pointer) | 3.55 s |
| immediate, `mkPtr` out of line (`mkBits64`) | 0.46 s |
| immediate, `mkPtr` inline | 0.26 s |
| native `TPtr` between the two FFI calls | **0.084 s** (equal to the hand-written C) |

The termui Demo has four `mkPointer` sites, none in a loop, so it gains
nothing; the gain is for code that makes pointers per iteration.

Native: `Rep`'s `RNative`/`RInlineNative` carry a `NativeTy` (`TPrim PrimType | TPtr`). `cfTypeNativeTy`
maps `CFPtr` and `CFStruct` to `TPtr`, so a `%foreign` call's pointer argument
and return are native (`ffiWorkerTable`), and `nativePromotionFor` makes a
let-bound FFI result `Native Ptr` when the body reads it at a native
position (`callArgNativeReads`). The IR shows it as `Native Ptr`; C declares
`IDRIS2RC2_Raw *`, converted to and from the boxed word by `mkPtr`/`toPtr`
and to `void *` at the call. `CFGCPtr` stays boxed.

A function parameter is native too (`ptrParamTable`, `ptrParams` in
`Compiler.RC2.DualABI`): a parameter whose every use is a call argument at a
`TPtr` position of a `%foreign` declaration, or of another function's pointer
parameter (found by a fixed number of rounds), becomes `Native Ptr` in the
function's worker; the boxed wrapper converts. `Loop.stripOwnership` now also
clears a promoted local from a worker call's `postDrop`, which struct return
(`doc/struct-return.md`) fills in before the promotion happens: the opaque
`IDRIS2RC2_Raw *` made the C compiler reject the stale `idris2rc2_drop`.

Not native yet: a pointer loop variable and a return value.
`Compiler.RC2.Loop`'s native-shadow analysis looks for `PrimType` uses only
(`BenchPtrWalk.idr`, a pointer advanced on every iteration: 0.41 s, against
about 0.1 s for hand-written C), and `returnEligibility` finds no native tail
for a function that ends in a `%foreign` call. Extending them to `NativeTy` is
the remaining work.
