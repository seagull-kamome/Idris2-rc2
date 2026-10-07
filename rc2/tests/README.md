# rc2 tests

What each test is for and how it is checked. `verify.sh` runs all of
them; its header comment says how to run one by hand.

## How `verify.sh` checks

`verify.sh` runs, in order:

1. **Build**: `idris2-rc2` and its runtime.
2. **refc-suite**: programs ported from upstream's RefC tests, see
   `refc-suite/README.md`.
3. **Smoke tests**: every `TestN/TestN.idr` below, compiled with
   `--directive dumprcexpr` and run.
4. **valgrind**: the leak-sensitive tests again, failing on any memory
   error or on any leak (`KNOWN_LEAK_BYTES` is empty).
5. **tsan**: the threaded tests under ThreadSanitizer (`tsan.sh`).

A smoke test's output is checked one of two ways:

| mark | expected output |
|---|---|
| refc | whatever real `idris2 --cg refc` prints for the same program; `TestN.expected` is a saved copy for `--no-refc` runs |
| saved | `TestN.expected` only, verified by hand once. For programs real RefC can't build or prints differently for a known reason (`NO_REFC_DIFF_TESTS`, each with its reason in `verify.sh`) |

Other marks in the tables below:

| mark | meaning |
|---|---|
| valgrind | in `LEAK_SENSITIVE_TESTS` |
| check.sh | `TestN/check.sh` greps the generated C or IR for something an output diff can't see (a pass fired, a value stayed native) |
| tsan | also run under ThreadSanitizer |
| C | a companion `TestN.c` is compiled and linked (its `.h` files are what the `%foreign` declarations name) |

## Merged tests

Tests that share a subject and are checked the same way (refc or saved)
are merged into one program: `TestN/TestN.idr` imports one module per
former test
(`TestN/Section.idr`, module `TestN.Section`) and calls each one's
`run`, formerly its `main`. A section's code is otherwise the original
test, doc comment included, and `TestN.expected` is the sections'
outputs in order. A merged test's companion `TestN.c` only
`#include`s the sections' own `.c` files.

A merged test is leak-checked if any of its sections was, so every
section must be leak-free: `Test68ClosureFastPathStackSafety` leaks by
design and stays on its own.

rc2 optimizes the whole program, so merging can change what a section
compiles to: a helper with one caller in the original test may have
several once merged and stop being inlined. When the merge was done,
each section's IR was compared definition by definition with its
original test's, and every difference was confirmed to be in printing
code (`show`, `printLn`) or in a shared Prelude function, not in what
the section tests. Deep-recursion sections keep their real check: they
overflow the C stack unless the pass they test fires.

Tests with a `check.sh` are not merged: it names functions in one
program's generated C.

## Language basics

| test | what it covers | checked |
|---|---|---|
| `Test111Basics/Basics` | `Integer` and `Int` recursion, a self-tail loop, `IORef`, strings, `map` over a range | refc valgrind |
| `Test111Basics/Recursion` | mutual and non-tail recursion | refc valgrind |
| `Test111Basics/Closures` | closures, higher-order functions, partial application (the boxed path) | refc valgrind |
| `Test3Data` | ADTs mixing native and boxed fields, nested `Maybe`/`List` | saved |
| `Test8EmptyCon` | nullary constructors as operands need no binding (`RCNull`/`RCEmptyCon`) | saved |
| `Test122LiftOrigin` | lambda lifting records where each lifted definition came from: parent, lambda or `Lazy`/`Inf` delay (`doc/lambda-lifting.md`) | refc valgrind check.sh |

## Numbers

| test | what it covers | checked |
|---|---|---|
| `Test112Numeric/NativeInts` | native inference for every signed/unsigned 8-64-bit type | refc valgrind |
| `Test112Numeric/ImmediateInts` | `Int`/`Int64`/`Bits64` immediates at their 63-bit boundaries (`doc/immediate-ints.md`) | refc valgrind |
| `Test112Numeric/ShiftWidth` | shifts by the full width or more give 0 or -1, as on Chez | refc valgrind |
| `Test112Numeric/ImmediateInteger` | `Integer` moving between immediates and GMP around the immediate range | refc valgrind |
| `Test7CastMatrix` | the `Cast` matrix for `Double` and `Char` that refc-suite's `integers` leaves out | saved |
| `Test49IntegerOpReuse` | boxed `Integer` ops reusing a unique operand's `mpz_t` (`doc/rop-reuse.md`) | saved valgrind |
| `Test83DoubleString` | locale-independent `Double` <-> `String` | saved |
| `Test91IntConstFold` | `Int` folded like `Int64`, large `Integer` literals read at compile time | refc valgrind check.sh |

## Native representation and the dual ABI

| test | what it covers | checked |
|---|---|---|
| `Test11DualABILeak` | a wrapper reading a boxed parameter natively leaked it (`doc/dual-abi.md`) | refc valgrind |
| `Test13NativeArgChain` | a parameter reached through a chain of native lets still gets a native worker | refc valgrind check.sh |
| `Test117ConAltNative/ConAltNative` | native shadows of destructured fields (`doc/con-alt-native.md`) | refc valgrind |
| `Test117ConAltNative/ConAltNativeLeadingDup` | a shadowed field whose first read had a `dup` right after the reuse offer | refc valgrind |
| `Test117ConAltNative/ConAltNativeConstCase` | a field read natively and also the scrutinee of a constant `case` keeps its boxed reference owned by every alt (heap-sized `Int`s, leak under valgrind) | refc valgrind |
| `Test90StructReturn` | small constructors returned by value (`doc/struct-return.md`) | refc valgrind check.sh |

## Loops and deep recursion

| test | what it covers | checked |
|---|---|---|
| `Test110Loop/SelfTailLoop` | self-tail calls to `goto`: parameter swaps, several recursive branches, passthrough arguments | refc valgrind |
| `Test110Loop/LoopContinuePostDrop` | a boxed continue argument read natively is dropped (`RLoopContinue.postDrop`) | refc valgrind |
| `Test110Loop/LoopInvariantParam` | invariant loop parameters elided | refc valgrind |
| `Test110Loop/LoopCallArgNativeShadow` | a parameter used only as a call argument gets a native shadow | refc valgrind |
| `Test110Loop/LoopConstClosureParam` | a loop parameter starting as a constant closure | refc valgrind |
| `Test113DeepRecursion/Trmc` | tail recursion modulo constructor, a million deep (`doc/trmc.md`) | refc valgrind |
| `Test113DeepRecursion/TrmcHoles` | TRMC with holes at different fields and several recursive fields | refc valgrind |
| `Test113DeepRecursion/TrmcMutual` | TRMC through another function | refc valgrind |
| `Test113DeepRecursion/ClosureCtx` | difference lists as chains of cells (`doc/closure-accumulator.md`) | refc valgrind |
| `Test113DeepRecursion/TeardownDeep` | dropping a million-long structure without recursing per cell | refc valgrind |

## Closures

| test | what it covers | checked |
|---|---|---|
| `Test18ClosureInPlaceGrow` | a unique closure grows in place as it is applied | refc valgrind |
| `Test68ClosureFastPathStackSafety` | a tail-position apply stays undispatched (bounded C stack); leaks by design, through a self-referential `IORef` | refc |
| `Test66ClosureFastPath` | the fast path for a shared closure receiving its last argument | saved valgrind |
| `Test92ArityRaise` | world arity raising (`doc/world-arity-raising.md`) | refc valgrind check.sh |
| `Test93ApplyFold` | a closure built and applied at once folds to a call | refc valgrind check.sh |

## Optimization passes

| test | what it covers | checked |
|---|---|---|
| `Test114Inline/SmallFunctionInline` | a small call-free helper spliced into its callers (`doc/inlining.md`) | refc valgrind |
| `Test114Inline/CompareFusionThroughCall` | a comparison behind a call fuses into `RCmpCase` | refc valgrind |
| `Test114Inline/DeadCodeInline` | a definition left with no caller is removed (`doc/dead-code-elim.md`) | refc valgrind |
| `Test114Inline/InlineCalleeFirst` | Criterion A judged on the callee's rewritten body, callees first: a call chain and compare-based `<=` vanish, recursion and an over-threshold sum of small pieces stay calls (`doc/inlining.md`) | refc valgrind check.sh |
| `Test17ConstFold` | constant folding of ops, cases, comparisons and casts | saved valgrind |
| `Test115ConstFoldClosure/ConstFoldClosure` | folding of closures, CAFs and case scrutinees | refc valgrind |
| `Test115ConstFoldClosure/ConstFoldClosureCallthrough` | dispatch through a folded interface dictionary | refc valgrind |
| `Test88KnownConFold` | a constructor built and only matched in one function is never built | refc valgrind check.sh |
| `Test87SpecConstCon` | specialization on a constant dictionary argument | refc valgrind check.sh |
| `Test87SpecConstCon/ConstConForwarding` | the same specialization carried through pure forwarders (also a recursive one); a dictionary that is also stored stays generic | refc valgrind check.sh |
| `Test106TransitiveSpec` | closure specialization along a chain of forwarding calls | refc valgrind check.sh |
| `Test106TransitiveSpec/SpecIterate` | the specialization passes iterate: a closure key that only exists inside a constant-dictionary clone is specialised in a second round | refc valgrind check.sh |
| `Test106TransitiveSpec/MultiApplySpec` | closure specialization of callees applying the closure 2-3 times; over the size threshold or with a capturing closure stays generic | refc valgrind check.sh |
| `Test99DeadArgs` | unused `where` arguments removed (`doc/dead-args.md`) | refc valgrind |
| `Test22BranchSinking` | a let moved into the one branch that reads it (`doc/branch-sinking.md`) | refc valgrind C |
| `Test79DupMerge` | adjacent `dup`s merged, `dup`/`drop` and `dup`/`postDrop` pairs cancelled (not against a consuming Integer op), alias `let x = w; drop [x]` renamed | refc valgrind check.sh |
| `Test36ReuseOfferUniqueLeak` | reuse offer dropping an unreferenced field on the unique path | refc valgrind |
| `Test44IORefExtPrimLeak` | `RExtPrim` arguments annotated (IORef leak) | refc valgrind |
| `Test86CafMemoization` | a top-level `unsafePerformIO` CAF evaluated once (`doc/caf-memoization.md`) | saved valgrind |
| `Test89CafDualABI` | a memoized CAF's body still gets DualABI, FFI inlining and Sink | refc valgrind check.sh |

## FFI and C interop

| test | what it covers | checked |
|---|---|---|
| `Test118FFI/FFIStrings` | direct FFI and `fastPack`/`fastConcat`/`fastUnpack` | refc valgrind C |
| `Test118FFI/WideDualABIWorker` | a dual-ABI worker with more parameters than the closure calling convention allows | refc valgrind C |
| `Test118FFI/FFIMalloc` | `System.FFI` `malloc`/`free` | refc valgrind C |
| `Test118FFI/FFIInteger` | `Integer` arguments and results of `%foreign` | refc valgrind C |
| `Test119FFINoRefc/GCPtrAliasString` | a `String` aliasing its `GCAnyPtr` argument is packed before the drop | saved valgrind C |
| `Test119FFINoRefc/ConstCFStringReturn` | a `const char *` return compiles under `-Werror` | saved valgrind C |
| `Test27FFIDualABI` | FFI calls inlined with native arguments; no constant argument dropped | saved valgrind check.sh C |
| `Test46FastPackUnconditional` | `fastPack`/`fastConcat` redirected to rc2's leak-free versions (`doc/fastpack-fix.md`) | refc valgrind |
| `Test24CStructSupport` | `getField`/`setField` on a struct rc2 declares (`doc/c-struct-support.md`) | saved valgrind C |
| `Test120CStruct/CgExternStruct` | structs declared by a header, `%cg rc2 externStruct=`, several names and modules | saved valgrind C |
| `Test120CStruct/CgExternStructPtrField` | `String`/`Ptr` fields of an extern struct | saved valgrind C |
| `Test59Export` | `%export` wrappers, one section per `CFType` shape (`doc/export-support.md`) | saved valgrind C |
| `Test28Utf8Strings` | `String` primitives by codepoint, not byte | saved valgrind C |

## Directives

| test | what it covers | checked |
|---|---|---|
| `Test30CgPragma` | `%cg rc2 <directive>` in source takes effect | refc check.sh |
| `Test121CgRuntime/CgExtraRuntime` | `%cg rc2 extraRuntime=<path>` | saved |
| `Test121CgRuntime/CgInlineRuntime` | `%cg rc2 inlineRuntime=<code>` | saved |
| `Test103MultiThreadedDirective` | `%cg rc2 multithreaded` makes refcounts atomic from the start | refc |

## Runtime and system libraries

| test | what it covers | checked |
|---|---|---|
| `Test82RuntimeLocale` | `rtInit` adopts the environment locale (`doc/runtime-lifecycle.md`) | saved C |
| `Test35NetworkLoopback` | rc2's `idrnet_*` port behind the `network` package | saved valgrind |
| `Test37SystemMisc` | `System.Directory`, signals, terminal, processes, extra `System.File` calls | refc valgrind |
| `Test42SupportMisc` | environment variables, PID, sleep, `System.Info` | saved valgrind |
| `Test102MultiThreadSwitch` | refcounts switch to atomic when the first thread starts (`doc/hybrid-refcount.md`) | refc valgrind tsan |
| `Test104ThreadStress` | values crossing eight threads | refc valgrind tsan |

## Benchmarks

`Bench*.idr` are not tests: `bench.sh` times them against real RefC
(see `rc2/BENCHMARKS.md`).
