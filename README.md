# idris2-rc-cg (rc2)

*[日本語](README.ja.md)*

**idris2-rc-cg** (**rc2**) is a fast, robust, and independent external C code generator backend for the [Idris 2](https://github.com/idris-lang/Idris2) dependently typed programming language.

Taking design cues from Idris 2's official C backend (`RefC`) for value representations, reference counting, and closure machinery, rc2 addresses fundamental limitations of upstream RefC. It provides a Perceus-style reference counting optimization pipeline, real POSIX multi-threaded concurrency, strict Unicode compliance, incremental compilation, and a comprehensive native C ABI toolkit.

rc2 is developed without modifying the upstream Idris 2 codebase. It lives in its own repository alongside an untouched reference checkout of Idris 2, building as a completely separate `idris2-rc2` executable.

---

## Table of Contents

- [Key Highlights](#key-highlights)
- [Quick Start](#quick-start) ([Environment](#1-environment-setup) / [Build & Install](#2-building-and-installing-rc2) / [Companion Library](#3-installing-the-support-library-rc2base) / [Compiling Programs](#4-compiling-and-running-programs) / [Profiling](#profiling-build-performance---timing))
- [Ecosystem and Developer Tools](#ecosystem-and-developer-tools) ([rc2base](#libsrc2base-native-c-abi-toolkit) / [text-re2](#libstext-re2-google-re2-regex-bindings) / [io_uring & notcurses](#other-bindings-io_uring-notcurses) / [rcexpr-lint](#toolsrcexpr-lint-ir-static-checker) / [rcexpr-diff](#toolsrcexpr-diff-ir-diff-tool))
- [Architecture and Optimization Pipeline](#architecture-and-optimization-pipeline) ([Repository Layout](#repository-layout) / [Compiler Structure](#compiler-structure-rc2) / [Optimization Passes](#ten-key-optimizations))
- [Deliberate Differences from Upstream RefC](#deliberate-differences-from-upstream-refc) ([Char](#1-full-unicode-scalar-values-for-char) / [String](#2-codepoint-semantics-and-nul-safe-string) / [pthread](#3-real-multithreaded-concurrency-pthread) / [%export](#4-native-c-abi-export-export) / [Lifecycle](#5-process-lifecycle-and-locale-independent-formatting) / [CAF & Lazy Memoization](#6-caf-and-lazy--inf-memoization))
- [%cg rc2 Directives](#cg-rc2-directives)
- [Incremental Compilation (--inc rc2)](#incremental-compilation---inc-rc2)
- [Testing and Quality Assurance](#testing-and-quality-assurance) ([verify.sh](#full-regression-suite-verifysh) / [snapshot & nopass](#verifying-non-altering-changes-snapshotsh-nopasssh) / [bench.sh](#performance-benchmarks-benchsh) / [Linter Tests](#ir-linter-unit-tests))
- [Status and Scope](#status-and-scope)

---

## Key Highlights

### Precise Reference Counting via a Dedicated IR Pass (Perceus / Koka Style)
Unlike RefC, which interleaves reference counting decisions ad-hoc during C emission, rc2 runs an explicit ownership analysis pass on an ANF-normalized intermediate representation (`RCExp`). Explicit `RDup`, `RDrop`, and `RFree` nodes are inserted once, keeping subsequent optimizations strictly sound and leaving C emission as a purely mechanical translation.

### In-Place Constructor Reuse
When pattern-matching deconstructs a value that is uniquely owned at runtime (reference count of 1), rc2 updates the existing heap cell in place instead of freeing and re-allocating a fresh cell of the same shape.

### Native Type Inference (Unboxing) and Dual ABI
Fixed-width numeric intermediate values are inferred as unboxed native values. A dual calling convention (`DualABI`) allows native values to cross function boundaries without boxing, while loop converters keep loop counters unboxed across the entire lifetime of self-tail-recursive and mutual-tail-recursive loops. Frequently accessed fields are cached as native shadows (`ConAltNative`).

### Real Multithreaded Concurrency (POSIX Threads)
Replacing upstream RefC's stubbed `exit(0)`, rc2 spawns real detached `pthread`s. A hybrid reference counting system uses fast, non-atomic instructions until a second thread is actually spawned, incurring zero atomic overhead in single-threaded workloads.

### Strict Unicode Compliance and NUL-Safe Strings
`Char` retains the full 32-bit Unicode scalar value, and `String` adheres strictly to codepoint-based semantics matching Chez Scheme. By storing an explicit byte-length field (`len`) in header padding, strings containing embedded NUL (`\0`) bytes round-trip and pattern-match safely without truncation.

### Native C ABI Wrapper Generation (`%export`)
rc2 generates genuine native C ABI wrappers for Idris 2 functions exported via `%export`. It automatically marshals and boxes/unboxes scalar types, GMP `Integer`, strings, pointers, and structs, allowing plain C code to invoke Idris functions without knowing internal runtime representations.

### Incremental Compilation (`--inc rc2`)
By compiling individual modules into separate object files (`.o`) and reusing them across builds, rc2 dramatically reduces compilation times during iterative development.

### Rich Native Ecosystem and Tooling
rc2 bundles an extensive native toolkit, including `libs/rc2base` (featuring an epoll-based HTTP/1.1 server and `MVar`), Google RE2 bindings, and a static IR analyzer (`tools/rcexpr-lint`) to statically detect use-after-free and double-drop bugs before execution.

---

## Quick Start

### 1. Environment Setup

After cloning the repository, generate the environment configuration file and source it into your shell:

```sh
./gen-env.sh
source env.sh
```

- `gen-env.sh` generates `env.sh`, setting `PATH` to point to the self-built compiler in `install/bin` and configuring support library paths (Chez Scheme must be available on `PATH` as `scheme`).
- `idris2-src/` is a clone of `https://github.com/idris-lang/Idris2.git` used solely as reference material and as the bootstrap source for the self-built Idris 2 compiler (never edited).
- `install/` is the local installation prefix for build artifacts (gitignored).

### 2. Building and Installing rc2

```sh
cd rc2
source ../env.sh
idris2 --build rc2.ipkg && idris2 --install rc2.ipkg
```

- Sourcing `../env.sh` places the self-built `install/bin/idris2` first on `PATH`. Because this compiler embeds `install/` as its default prefix at bootstrap time, exporting `IDRIS2_PREFIX` is not required.
- *(Note: If building using nixpkgs' `idris2`, `export IDRIS2_PREFIX="$(cd .. && pwd)/install"` must be specified explicitly, as nixpkgs points to a read-only nix store path by default).*
- The build produces the executable `rc2/build/exec/idris2-rc2`.
- The runtime library (`libidris2rc2.a`) linked into every rc2-compiled program resides in `rc2/support/rc2/` and is built and installed automatically via `rc2.ipkg` hooks (it can also be rebuilt independently with `make -C support/rc2 && make -C support/rc2 install`).

### 3. Installing the Support Library (rc2base)

For almost all practical programs, the companion support library [`libs/rc2base/`](#libsrc2base-native-c-abi-toolkit) is required. It supplies C implementations for upstream `%foreign` primitives that lack RefC backends (such as GMP-backed `Integer` arithmetic, parts of `Data.Buffer`, `Data.Double` constants, and `System.Random`).

```sh
cd ..
source env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)
```

- Because the self-built `idris2` defaults to searching its own installation prefix (`install/`), packages installed there are discovered automatically without extra package-path configuration.

### 4. Compiling and Running Programs

Compile Idris 2 programs using the `rc2` codegen backend:

```sh
./rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base Program.idr -o program
./program
```

- Generated C code is compiled with `-O2` by default, matching the runtime library.
- To disable optimizations, pass `CFLAGS=-O0` or configure `IDRIS2_CFLAGS`.

### Profiling Build Performance (--timing)

Use upstream Idris 2's `--timing N` flags to inspect codegen pipeline performance:

- `--timing 1`: Displays total code generation time ("Code generation overall").
- `--timing 2`: Breaks down the total into individual rc2 pipeline stages labeled `rc2: <stage>` (inline, RC normalize, ConstFold, CAF memoization, RC annotate/reuse/ConAltNative, mutual loop, loop conversion, sink, dual ABI, dead-code elimination, dup merge, C generation, C compile, C link).
- `--timing 3`: Further breaks down compute-intensive stages (such as inlining and loop conversion) into named sub-phases.
- Stages disabled via `--directive no<stage>` omit timing lines entirely rather than showing spurious zero durations.

---

## Ecosystem and Developer Tools

### `libs/rc2base/`: Native C ABI Toolkit

```
libs/rc2base/
├── rc2base.ipkg   Idris2 package: Control.Concurrent.{MVar,Atomic},
│                  Data.Text/Data.TextBuffer, Data.String.{FFI,RC2}, Data.Buffer.RC2,
│                  Data.Double.{RC2,Convert}, Data.IORef.RC2, Data.Integer.GMP, Data.Queue,
│                  Language.RCExpr.{AST,Lexer,Parser},
│                  Network.{RC2,URL}, Network.HTTP.{Route,Router,Server},
│                  System.Concurrency.RC2, System.FFI.C.{Array,Ptr,Sizeof},
│                  System.GC.RC2, System.IO.Epoll, System.IO.MemStream,
│                  System.Random.Xoroshiro{128PlusPlus,64StarStar},
│                  Text.Encoding.UTF8, Text.Regex.POSIX
├── src/           Idris2 source for the modules above
├── support/c/     C shims (libidris2rc2base.a) built via prebuild/postinstall hooks
├── doc/           Design notes for major components (http-router.md, http-server.md, regex-posix.md, url.md)
└── tests/         Unit tests per module (verify.sh)
```

A foundational companion package designed to supply capabilities missing from or incomplete in upstream `base` and `contrib`:

- **High-Performance Web & Networking**: An event-driven HTTP/1.1 server on `System.IO.Epoll` (`Network.HTTP.Server`), a type-safe Express-style router (`Network.HTTP.Route` / `Router`), and URL parsing (`Network.URL`).
- **Concurrency & Synchronization**: Haskell-style `MVar` and atomic counters (`Control.Concurrent.*`), native OS threads, and mutexes (`System.Concurrency.RC2`).
- **Low-Level C Interop & Memory**: POSIX regex (`Text.Regex.POSIX`), GMP integer arithmetic (`Data.Integer.GMP`), memory buffers, raw UTF-8 byte conversions (`Text.Encoding.UTF8`), and explicit reference counting manipulation for opaque FFI values (`System.GC.RC2`).
- **Compiler Tooling**: Parsers for rc2's dumped IR (`Language.RCExpr.*`).

See [`libs/rc2base/README.md`](libs/rc2base/README.md) for module-by-module design notes. Note that the `postinstall` hook copies libraries to `lib/`, which is essential because rc2 does not auto-discover dependency `lib/` directories.

### `libs/text-re2/`: Google RE2 Regex Bindings

```
libs/text-re2/
├── text-re2.ipkg   Idris2 package: Text.Regex.RE2
├── src/            Idris2 source
├── support/c/      C++ shim (re2_util.cpp, libidris2rc2re2.so)
├── doc/regex.md    Design rationale for package separation
└── tests/          TestRE2.idr
```

Bindings to Google's [RE2](https://github.com/re2) regex engine, offering linear-time matching guarantees. Separated from `rc2base` to keep `rc2base` strictly dependent on standard C toolchains (`gcc` / `ar`); RE2 requires a C++ compiler (`g++`) and dozens of Abseil flags (`pkg-config --libs re2`) linked into a dedicated shared library (`libidris2rc2re2.so`). For typical use cases, `Text.Regex.POSIX` in `rc2base` provides zero-dependency regex matching. See [`libs/text-re2/README.md`](libs/text-re2/README.md) for details.

### Other Bindings (io_uring, notcurses)

- **`libs/iouring/`**: Bindings to Linux's high-performance asynchronous I/O framework io_uring (`System.IO.Uring`). See [`libs/iouring/README.md`](libs/iouring/README.md).
- **`libs/notcurses/`**: rc2-specific bindings for building rich terminal UIs with notcurses (`System.Notcurses`). See [`libs/notcurses/README.md`](libs/notcurses/README.md).

### `tools/rcexpr-lint/`: IR Static Checker

```
tools/rcexpr-lint/
├── RcexprLint.idr  CLI: inspects .rcexpr dumps, reports anomalies and metrics
├── Lint.idr        Core verification rules
├── Metrics.idr     Static counts (definitions, allocations, closures, calls, dup/drop)
├── README.md       Detection scope and report guide
└── tests/          Test fixtures and verify.sh
```

A static analysis tool that re-derives reference count transitions directly from `RCExp` IR dumps (`--directive dumprcexpr`) to verify memory safety at compile time:

- **Detectable Issues**: Catches **use-after-free** (reading a `Boxed` local whose count has reached zero) and **double-drop** (dropping an already-freed variable).
- **Background**: Developed after three elusive ownership bugs were encountered in `Sink.idr`. Unlike valgrind, which requires specific test execution and memory reuse to expose flaws, this tool checks *any* compilable program statically.
- **Static Metrics**: Reports counts of definitions, fresh allocations versus in-place cell reuses, closures, function calls, and `dup`/`drop` sites to evaluate optimization passes.

```sh
source env.sh
rc2/build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr Prog.idr -o prog
tools/rcexpr-lint/build/exec/rcexpr-lint build/exec/prog.rcexpr
```

See [`tools/rcexpr-lint/README.md`](tools/rcexpr-lint/README.md) for rules, exit codes, and known limitations (fields bound in `case` branches lack explicit `Rep` and are assumed `Boxed`).

### `tools/rcexpr-diff/`: IR Diff Tool

Compares two `.rcexpr` IR dumps definition by definition. By normalizing variable identifiers in order of appearance and stripping compiler-generated name counters, it isolates exactly which definitions changed between compiler revisions without cascading variable renaming noise. See [`tools/rcexpr-diff/README.md`](tools/rcexpr-diff/README.md).

---

## Architecture and Optimization Pipeline

### Repository Layout

```
.
├── env.sh          Generated environment variables (source before build/run; gitignored)
├── gen-env.sh       Regenerates env.sh (requires Chez Scheme on PATH as scheme)
├── idris2-src/      Clone of github.com/idris-lang/Idris2 (reference & bootstrap source; gitignored)
├── install/         Local install prefix for self-built toolchain and rc2 (gitignored)
├── libs/rc2base/    Companion native C ABI support library
├── libs/text-re2/   Google RE2 regex bindings
├── libs/iouring/    io_uring bindings (System.IO.Uring)
├── libs/notcurses/  notcurses bindings (System.Notcurses)
├── tools/           IR verification and diff tools (rcexpr-lint, rcexpr-diff)
└── rc2/             Core compiler backend
```

### Compiler Structure (`rc2/`)

rc2 consumes upstream case trees, transforms them through its proprietary ANF intermediate representation `RCExp`, applies optimization passes, and emits C:

```
rc2/
├── rc2.ipkg           Idris2 package configuration; builds idris2-rc2 executable
├── src/Compiler/RC2/
│   ├── RCExp.idr        IR definition: ANF-normalized expressions with ownership annotations
│   ├── Util.idr         Shared leaf-level helpers (designed to avoid import cycles)
│   ├── RC.idr           case tree -> RCExp: Phase 1 (normalization), Phase 2 (dup/drop/free insertion)
│   ├── Types.idr        native / boxed representation inference (Rep)
│   ├── InlineCExp.idr   Whole-program inlining before lambda lifting
│   ├── LateInline.idr   Whole-program inlining after loop conversion
│   ├── ArityRaiseCExp.idr, ArityRaise.idr
│   │                    World argument arity raising
│   ├── DeadArgs.idr     Removes unused arguments in where functions
│   ├── LazyCaf.idr      Transforms top-level Delay into memoized CAFs
│   ├── LazyFold.idr     Unfolds singly forced lazy values into direct calls
│   ├── ConstFold.idr    Constant folding for ExtPrim, arithmetic, comparisons, cases, and closures
│   ├── PushCon.idr      Pushes case expressions into constructor tails to expose fold opportunities
│   ├── SpecClosure.idr  Callee specialization for constant closures and interface dictionaries
│   ├── Reuse.idr        In-place constructor cell reuse
│   ├── ConAltNative.idr Caches destructured fields repeatedly accessed as native values
│   ├── DeadVars.idr     Clears destructured fields that are never referenced
│   ├── MutualLoop.idr   Merges mutually tail-recursive functions into unified loops
│   ├── Trmc.idr         Tail Recursion Modulo Constructor (TRMC) optimization
│   ├── ClosureCtx.idr   Maintains difference-list parameters as cell chains
│   ├── Loop.idr         Self-tail-call -> goto conversion and loop-invariant hoisting
│   ├── Sink.idr         Branch-local let sinking
│   ├── DualABI.idr      Dual calling convention across function boundaries and struct return
│   ├── DeadCode.idr     Whole-program mark-and-sweep dead-code elimination
│   ├── DupMerge.idr     Batches consecutive RDup nodes on the same variable
│   ├── Emit.idr         Mechanical translation from RCExp to C
│   ├── Emit/Util.idr        Name mangling, literal/value emission, closures, FFI type mapping
│   ├── Emit/Foreign.idr     %foreign / %export C wrapper generation and FFI marshalling
│   ├── Emit/ExternRefs.idr  Forward declaration walkers for incremental compilation
│   ├── Pretty.idr       Human-readable RCExp dumper (--directive dumprcexpr)
│   ├── CC.idr           C compiler driver and linker orchestration
│   └── RC2.idr          Backend entry point and codegen pipeline registration
├── support/rc2/       Runtime library (libidris2rc2.a)
├── doc/               Detailed per-pass design notes (see index in AGENT.md)
└── tests/             Regression and benchmark suites
```

### Ten Key Optimizations

rc2's pipeline (wired in `toRCDefs` within `Compiler.RC2.RC2`) consists of modular, individually-toggleable passes:

1. **Independent Reference Counting Pass (`RC.idr`)**:  
   Instead of interleaving refcount tracking inside codegen as RefC does, rc2 runs an ownership analysis pass (Perceus/Koka style) before C emission. Explicit `RDup`, `RDrop`, and `RFree` nodes are inserted into `RCExp`, allowing subsequent passes to optimize around ownership while `Emit.idr` focuses purely on mechanical translation.
2. **Native (Unboxed) Representation Inference (`Types.idr`, `DualABI.idr`)**:  
   Infers unboxed representations for fixed-width numeric intermediates and shares them across function boundaries via a dual Boxed/native calling convention (`DualABI`). Loop counters stay unboxed throughout loops (`Loop` / `MutualLoop`), and frequently read fields are cached as native shadows (`ConAltNative`).
3. **In-Place Constructor Reuse (`Reuse.idr`)**:  
   When a pattern match destructs a value and immediately reconstructs a constructor of the same shape, the existing heap cell is overwritten in place if uniquely owned at runtime (reference count of 1), avoiding reallocation.
4. **Loop-Invariant Hoisting and Parameter Pruning (`Loop.idr`)**:  
   Loop parameters that remain constant across iterations are pruned from the loop's signature, and invariant expressions in unconditional prefixes are hoisted ahead of the loop.
5. **Branch-Local Sinking (`Sink.idr`)**:  
   `let`-bound computations used solely within a single branch are sunk directly into that branch, avoiding wasted computation on other code paths.
6. **Whole-Program Inlining and Constant Folding (`InlineCExp.idr`, `LateInline.idr`, `ConstFold.idr`)**:  
   Inlines small, call-free functions and single-call-site callees. Folds constant `ExtPrim`s, arithmetic, comparisons, and branches. Named top-level closures with no captures fold into immortal constants, allowing interface dictionary records to be eliminated entirely (using a fixpoint algorithm of up to 4 rounds).
7. **Closure Dispatch Fast Path (`support/rc2/idris2rc2_rt.c`)**:  
   When applying the final argument to a shared closure, rc2 dispatches directly into the target function rather than allocating a temporary closure only to discard it immediately.
8. **Advanced Recursion Transformations**:  
   Converts constructor-tail recursion (`x :: f xs`) into iterative loops that patch cell holes (Tail Recursion Modulo Constructor, `Trmc.idr`). Maintains difference-list accumulators (`c . (y ::)`) as cell chains (`ClosureCtx.idr`).
9. **Specialization and Calling Convention Rewriting**:  
   Clones and specializes functions called with constant closures or interface dictionaries (`SpecClosure.idr`). Performs world argument arity raising (`ArityRaise.idr`), removes unused `where` arguments (`DeadArgs.idr`), and returns constructors with four or fewer fields as C structs by value rather than heap allocations (`DualABI.idr`).
10. **Low Runtime Overhead (Immediate Ints & Hybrid Refcounting)**:  
    Integers fitting in 62 bits (`Int`, `Int64`, `Bits64`, `Integer`) live directly within pointer words without heap allocations. Reference counting operations remain plain non-atomic instructions until a second thread is actually spawned.

---

## Deliberate Differences from Upstream RefC

rc2 addresses critical bugs and omissions in upstream RefC, achieving semantic consistency with the Chez Scheme backend:

### 1. Full Unicode Scalar Values for Char

Upstream RefC narrows `Char` throughout its runtime to a 1-byte C `char`, breaking characters outside the ASCII range. rc2 preserves full 32-bit Unicode scalar values (`0..0x10FFFF`), mapping out-of-range values safely to NUL. As an intentional exception, `CFStruct` fields bound as `Char` retain a 1-byte `char` to guarantee exact byte layout compatibility with native C library structures.

### 2. Codepoint Semantics and NUL-Safe String

While RefC processes strings byte-wise, rc2 implements codepoint-based indexing, slicing, and length calculation in accordance with the language specification (malformed byte sequences decode safely to `U+FFFD`). Because strings are stored as UTF-8 byte buffers, codepoint operations like `strIndex` scale with O(N) complexity.

Furthermore, upstream RefC represents strings as bare `char *`, truncating at the first embedded NUL (`\0`). rc2's `IDRIS2RC2_String` stores an explicit byte length (`len`) inside header padding, allowing embedded NUL bytes to round-trip and pattern-match accurately via `memcmp`. (Crossing standard C FFI boundaries as `char *` still respects C NUL-termination).

### 3. Real Multithreaded Concurrency (pthread)

Upstream RefC stubs `prim__fork` with `exit(0)` and marks `System.Concurrency` primitives as Scheme-only foreign declarations. rc2 spawns real detached POSIX threads (`pthread`) and uses `%foreign_impl` to map upstream declarations (`Mutex`, `Condition`, `Semaphore`, `Barrier`, `Channel`) onto genuine pthread objects (accessible seamlessly by importing `System.Concurrency.RC2` from `libs/rc2base`). It additionally introduces joinable thread primitives (`forkJoin`, `join`, `JoinHandle`). Non-blocking channel operations assume tag=1/arity=1 for `Prelude.Maybe`'s `Just` constructors.

### 4. Native C ABI Export (%export)

Upstream RefC ignores `%export` pragmas completely. rc2 generates true native C ABI wrappers that marshal and unbox parameters/returns for scalars, `Ptr`/`AnyPtr`, `GCPtr` (arguments only), GMP `Integer`, strings, and structs. Plain C programs can call exported Idris functions directly without linking Idris runtime headers.

### 5. Process Lifecycle and Locale-Independent Formatting

rc2's generated `main()` invokes lifecycle hooks `idris2rc2_rtInit()` and `idris2rc2_rtFinish()`. `rtInit` calls `setlocale(LC_ALL, "")` so POSIX regex functions correctly interpret UTF-8 environments, while `rtFinish` flushes standard streams via `fflush(NULL)`.

Number conversions (`Double <-> String`) employ a custom decimal converter that outputs exact, minimal round-trip strings, remaining entirely independent of locale decimal point conventions (`LC_NUMERIC`).

### 6. CAF and Lazy / Inf Memoization

In upstream RefC, zero-argument top-level definitions (CAFs) were re-evaluated on every reference. For example, `counter = unsafePerformIO (newIORef 0)` generated separate IORef instances upon each access. rc2 inserts `RMemoize` IR nodes after constant folding to atomically evaluate, cache, and share results across all references (producing the expected `0 1 2` output matching Chez Scheme).

Similarly, upstream RefC lowered `Delay`/`Force` into standard closures, re-running delayed computations on every force. rc2 preserves dedicated `RDelay` and `RForce` nodes, caching the first evaluation result via `idris2rc2_force`.

---

## %cg rc2 Directives

rc2 accepts `%cg rc2 <directive>` pragmas in source files and `--directive VALUE` command-line flags:

- **Pass Toggling (A/B Testing & Diagnostics)**: Disable individual optimization stages, e.g. `--directive noloop` or `--directive noconstfold`.
- **Debug Dumps**: Emit human-readable representations via `dumprcexpr`, `dumpdualabi`, or `dumpcc`.
- **Inline C Splicing**: Embed external C code directly with `extraRuntime=<path>` (including C source files) or `inlineRuntime=<code>` (inline C snippets) without modifying CFLAGS/LDFLAGS.

See [`rc2/doc/directives.md`](rc2/doc/directives.md) for the complete list and design rationale.

---

## Incremental Compilation (--inc rc2)

RefC does not support incremental builds, forcing a full rebuild on every compilation. rc2 implements upstream's `Codegen.incCompileFile` / `incExt` architecture:

```sh
idris2-rc2 --cg rc2 --inc rc2 -o program Program.idr
```

- Each module compiles to an individual `.o` object file once, reusing existing objects when source files remain unchanged.
- Verified across 272 modules across `prelude`, `base`, `linear`, `contrib`, and `network` without missing incremental symbols.
- **Current Limitation**: C struct accessors (`getField` / `setField` / `Struct`) require whole-program inlining and are currently incompatible with `--inc rc2` (resulting in link-time undefined reference errors; whole-program builds are unaffected). Rebuilding the standard libraries once with `--inc rc2` is required to realize full build acceleration. See [`rc2/doc/incremental-compile.md`](rc2/doc/incremental-compile.md).

---

## Testing and Quality Assurance

### Full Regression Suite (verify.sh)

```sh
cd rc2/tests
source ../../env.sh
./verify.sh
```

`verify.sh` executes the comprehensive test pipeline:
1. Builds `idris2-rc2` and the runtime library.
2. Runs the ported upstream RefC regression suite (`rc2/tests/refc-suite/`).
3. Compiles and verifies 55 hand-written smoke tests against saved `.expected` outputs.
4. Executes leak-sensitive tests under `valgrind --leak-check=full`.
5. Runs multithreaded tests under **ThreadSanitizer (TSan)** via `tsan.sh`.
6. Checks all smoke test IR dumps with `tools/rcexpr-lint`.

**Key Options**:
- `--skip-build`: Skip compiler rebuild.
- `--no-valgrind`: Skip valgrind checks for faster execution.
- `--valgrind-all`: Run all tests under valgrind.
- `--no-refc-suite` / `--no-tsan`: Exclude specific test suites.
- `--directive VALUE`: Pass directives to the compiler (e.g. `--directive noloop`).
- `--regen-expected`: Regenerate smoke test expected outputs.
- `TEST_TIMEOUT` environment variable (default: 60s; 10x for valgrind/TSan).

### Verifying Non-Altering Changes (snapshot.sh, nopass.sh)

For refactorings and optimizations that should preserve compiler output identically:
- `snapshot.sh save DIR` / `snapshot.sh diff DIR`: Performs byte-for-byte diffs of generated IR dumps and C output across runs.
- `nopass.sh`: Runs smoke tests with optimization stages disabled one by one to reveal hidden inter-pass dependencies.

### Performance Benchmarks (bench.sh)

```sh
cd rc2/tests
./bench.sh
```

Times `rc2/tests/Bench*.idr` compiled with both `idris2-rc2` and upstream `idris2 --cg refc`, reporting wall-clock speedup ratios (`--runs N` sets iterations; `--missing-containers` adds external container benchmarks). Results and methodology are recorded in [`rc2/BENCHMARKS.md`](rc2/BENCHMARKS.md).

### IR Linter Unit Tests

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

---

## Status and Scope

rc2 operates as a production-grade external C code generator backend.

### Verified Capabilities

- **Memory & Representation Optimizations**: In-place constructor reuse, native representation inference and dual calling conventions (`DualABI`), struct return by value, merged duplicate refcount operations (`DupMerge`), immediate integers, hybrid refcounting.
- **Control Flow & Optimization Passes**: Self-tail-call and mutual-tail-call loop conversions with loop-invariant hoisting, Tail Recursion Modulo Constructor (TRMC), branch-local let sinking, whole-program inlining, constant folding, dead-code elimination, closure and dictionary specialization, world arity raising.
- **Semantic Fixes & Build Infrastructure**: Atomic CAF and Lazy/Inf memoization, incremental compilation (`--inc rc2`).
- **Standard Library Support**: Native support for `Data.Buffer`, `System.Clock`, and standard `network` packages.

### Active Investigations and Tradeoffs

Details regarding ongoing investigations (e.g., native tail delegation, small-object allocators) and deliberate architectural tradeoffs are documented in [`TODO.md`](TODO.md). Detailed design rationales and bug fix histories are located in [`rc2/doc/`](rc2/doc/).
