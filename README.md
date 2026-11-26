# idris2-rc-cg (rc2)

*[日本語](README.ja.md)*

**idris2-rc-cg** (**rc2**) is a fast, robust, and independent external C code generator backend for the [Idris 2](https://github.com/idris-lang/Idris2) dependently typed programming language.

Taking design cues from Idris 2's official C backend (`RefC`) for value representations, reference counting, and closure machinery, rc2 addresses fundamental limitations of upstream RefC. It provides a Perceus-style reference counting optimization pipeline, real POSIX multi-threaded concurrency, strict Unicode compliance, incremental compilation, and a comprehensive native C ABI toolkit.

rc2 is developed without modifying the upstream Idris 2 codebase. It lives in its own repository alongside an untouched reference checkout of Idris 2, building as a completely separate `idris2-rc2` executable.

---

## Table of Contents

- [Key Highlights](#key-highlights)
- [Quick Start](#quick-start) ([Environment](#1-environment-setup) / [Build & Install](#2-building-and-installing-rc2) / [Companion Library](#3-installing-the-support-library-rc2base) / [Compiling Programs](#4-compiling-and-running-programs) / [Self-Hosting](#5-building-the-compiler-with-rc2-itself-self-hosting-no-chez-scheme) / [Profiling](#profiling-build-performance---timing))
- [Ecosystem and Developer Tools](#ecosystem-and-developer-tools) ([rc2base](#libsrc2base-native-c-abi-toolkit) / [control-async](#libscontrol-async-tasks-and-non-blocking-sockets) / [web](#libsweb-http-client-and-servers) / [text-re2](#libstext-re2-google-re2-regex-bindings) / [notcurses & termui](#other-bindings-notcurses-termui) / [rcexpr-lint](#toolsrcexpr-lint-ir-static-checker) / [rcexpr-diff](#toolsrcexpr-diff-ir-diff-tool) / [c-split](#toolsc-split-c-file-splitter) / [idris2-browser](#toolsidris2-browser-package-browser))
- [Architecture and Optimization Pipeline](#architecture-and-optimization-pipeline) ([Repository Layout](#repository-layout) / [Compiler Structure](#compiler-structure-rc2) / [Pipeline Order](#pipeline-order) / [Optimization Passes](#ten-key-optimizations))
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
rc2 bundles an extensive native toolkit, including `libs/rc2base` (featuring `MVar`), `libs/control-async` (a `Task` scheduler), `libs/web` (an HTTP client and HTTP/1.1 servers), Google RE2 bindings, and a static IR analyzer (`tools/rcexpr-lint`) to statically detect use-after-free and double-drop bugs before execution.

---

## Quick Start

### 1. Environment Setup

After cloning the repository, generate the environment configuration file and source it into your shell:

```sh
./gen-env.sh
source env.sh
```

- `gen-env.sh` generates `env.sh`, setting `PATH` to point to the self-built compiler in `install/bin` and configuring support library paths. The Chez Scheme backend step of `idris2 --build` needs Chez Scheme: Idris 2 takes the executable from the `CHEZ` environment variable, and otherwise looks for `chez`, `chezscheme`, `chez-scheme`, `chezscheme9.5` or `scheme` on `PATH` (`gen-env.sh` itself only checks for `scheme`).
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

### 5. Building the Compiler with rc2 Itself (Self-Hosting, No Chez Scheme)

> **Experimental.** The rc2-built compiler is slower than the Chez-built one: it executes about 2.1 times as many instructions building `libs/prelude`, and building `idris2-rc2-norepl` takes about 12 minutes with it against 10 with the Chez-built compiler (C compilation included). Use it to try out rc2 without Chez Scheme, not as your everyday compiler. `rc2/doc/self-hosting.md` has the numbers.

`idris2-rc2-norepl` is the same compiler with a driver that has no REPL (`rc2/doc/norepl.md`). rc2 can build it, and the result builds the libraries and itself, and type-checks the compiler's API package, with the same output as the Chez-built compiler (`rc2/doc/self-hosting.md` has the findings, the numbers and what is still open).

```sh
cd rc2
source ../env.sh
idris2 --build rc2.ipkg && idris2 --install rc2.ipkg          # 1. as in step 2 (Chez builds idris2-rc2 and the rc2 package)
build/exec/idris2-rc2 --cg rc2 --build rc2-norepl.ipkg        # 2. rc2 builds the compiler: about 10 minutes with the Chez-built idris2-rc2
build/exec/idris2-rc2-norepl --cg rc2 Program.idr -o program  # 3. it is a compiler like idris2-rc2
```

- Step 2 produces a 114 MB C file and compiles it, so most of the time is the C compiler. No Chez Scheme runs in it, but step 1 still does: the first compiler and the `.ttc` files of the libraries come from the Chez-built `idris2`.
- `rc2/tests/selfhost.sh [stage1|libs|api|fixed|all]` repeats the experiment under `rc2/build/selfhost`: `libs` builds `prelude`, `base`, `linear`, `network`, `contrib` and `test` with the rc2-built compiler, `api` type-checks `idris2api`, and `fixed` builds `idris2-rc2-norepl` again and checks that the C is the same, and `diff` compiles `rc2/tests` with both compilers and compares the C.
- The rc2-built compiler has no REPL (`--ide-mode`, `--yaffle`, `--ttm`, `--repl` and `--client` are refused) and is slower than the Chez-built one (see the note at the top of this section).

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
│                  Data.Text/Data.TextBuffer, Data.String.{FFI,RC2},
│                  Data.Double.{RC2,Convert}, Data.IORef.RC2, Data.Integer.GMP, Data.Queue,
│                  Language.RCExpr.{AST,Lexer,Parser},
│                  Network.{RC2,URL},
│                  System.Concurrency.RC2, System.FFI.C.{Array,Ptr,Sizeof},
│                  System.GC.RC2, System.Linux.Epoll,
│                  System.Random.Xoroshiro{128PlusPlus,64StarStar},
│                  Text.Encoding.UTF8, Text.Regex.POSIX
├── src/           Idris2 source for the modules above
├── support/c/     C shims (libidris2rc2base.a) built via prebuild/postinstall hooks
├── doc/           Design notes for major components (regex-posix.md, url.md, ...)
└── tests/         Unit tests per module (verify.sh)
```

A foundational companion package designed to supply capabilities missing from or incomplete in upstream `base` and `contrib`:

- **Networking**: Socket IO into buffers (`Network.RC2`), and URL parsing (`Network.URL`).
- **Concurrency & Synchronization**: Haskell-style `MVar` and atomic counters (`Control.Concurrent.*`), native OS threads, and mutexes (`System.Concurrency.RC2`).
- **Low-Level C Interop & Memory**: POSIX regex (`Text.Regex.POSIX`), GMP integer arithmetic (`Data.Integer.GMP`), memory buffers, raw UTF-8 byte conversions (`Text.Encoding.UTF8`), and explicit reference counting manipulation for opaque FFI values (`System.GC.RC2`).
- **Compiler Tooling**: Parsers for rc2's dumped IR (`Language.RCExpr.*`).

See [`libs/rc2base/README.md`](libs/rc2base/README.md) for module-by-module design notes.

### `libs/control-async/`: Tasks and Non-blocking Sockets

The `Task` monad (spawn/both/race, cancellation, timers) with a scheduler over `epoll` and optionally `io_uring`, `Ref`/`MVar`/`Chan` for tasks on several threads, and non-blocking sockets for it (`Control.Task*`, `Network.Async`). It depends on `rc2base` and was split off it; `web` and `termui` run on it. Build it with `libs/control-async/tests/verify.sh` (after `libs/rc2base/tests/verify.sh`) and compile programs with `-p control-async -p rc2base -p contrib`. See [`libs/control-async/README.md`](libs/control-async/README.md).

### `libs/web/`: HTTP Client and Servers

An HTTP/1.1 server on `System.Linux.Epoll` (`Network.HTTP.Server`) with a type-safe Express-style router (`Network.HTTP.Route` / `Router`), a second server made of `Control.Task` tasks with static files, CGI, a reverse proxy and a URL rewriter (`Network.Async.HTTP.*`), and a libcurl client with an OpenAI-compatible chat client and OAuth 2.0 (PKCE) login (`Network.HTTP.Client.*`). It depends on `rc2base` and `control-async` and was split off `rc2base`. Build it with `libs/web/tests/verify.sh` (after `libs/rc2base/tests/verify.sh` and `libs/control-async/tests/verify.sh`) and compile programs with `-p web -p control-async -p rc2base -p contrib`. See [`libs/web/README.md`](libs/web/README.md).

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

### Other Bindings (notcurses, termui)

- **`libs/notcurses/`**: rc2-specific bindings for building rich terminal UIs with notcurses (`System.Notcurses`). See [`libs/notcurses/README.md`](libs/notcurses/README.md).
- **`libs/termui/`**: Ink-style terminal UI library: layout EDSL, flexbox-like layout engine and differential screen updates over plain ANSI (`TermUI.*`, work in progress). See [`libs/termui/README.md`](libs/termui/README.md).

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

### `tools/c-split/`: C File Splitter

Splits the one `.c` file rc2 writes for a whole program into a shared header and several parts, so the C compiler takes it in pieces and in parallel. With `--directive writecc --directive nocc`, rc2 writes its compile and link commands next to the `.c` instead of running them, and `c-split --commands` turns them into a Makefile. For the self-hosted compiler (111 MB of C), `make -j4` takes 5 minutes at 0.95 GB instead of 9 minutes at 2.2 GB in one `clang`. See [`tools/c-split/README.md`](tools/c-split/README.md).

### `tools/idris2-browser/`: Package Browser

A terminal browser for the Idris 2 packages installed in an environment: the packages with their statistics, their modules, and each module's definitions with kinds, types and doc comments, with a search over every definition name. An indexer built on `idris2api` (Chez) reads the installed TTC files into a JSON index whose format is public, so an editor plugin could read it too; the screen is built with rc2 and `termui`. See [`tools/idris2-browser/README.md`](tools/idris2-browser/README.md).

---

## Architecture and Optimization Pipeline

### Repository Layout

```
.
├── env.sh          Generated environment variables (source before build/run; gitignored)
├── gen-env.sh       Regenerates env.sh (checks that Chez Scheme is on PATH as scheme)
├── idris2-src/      Clone of github.com/idris-lang/Idris2 (reference & bootstrap source; gitignored)
├── install/         Local install prefix for self-built toolchain and rc2 (gitignored)
├── libs/rc2base/    Companion native C ABI support library
├── libs/control-async/  Task monad, scheduler and non-blocking sockets (needs rc2base)
├── libs/web/        HTTP client and servers (needs rc2base, control-async)
├── libs/text-re2/   Google RE2 regex bindings
├── libs/notcurses/  notcurses bindings (System.Notcurses)
├── libs/termui/     terminal UI library (TermUI.*)
├── tools/           IR verification and diff tools, C file splitter, package browser (rcexpr-lint, rcexpr-diff, c-split, idris2-browser)
└── rc2/             Core compiler backend
```

### Compiler Structure (`rc2/`)

rc2 consumes upstream case trees, transforms them through its proprietary ANF intermediate representation `RCExp`, applies optimization passes, and emits C:

```
rc2/
├── rc2.ipkg           Idris2 package configuration; builds idris2-rc2 executable
├── src/Compiler/RC2/  The passes are listed in pipeline order below; besides them:
│   ├── RCExp.idr        IR definition: ANF-normalized expressions with ownership annotations
│   ├── Util.idr         Shared leaf-level helpers (designed to avoid import cycles)
│   ├── Rewrite.idr      Whole-tree rewrites several passes share
│   ├── Types.idr        native / boxed representation inference (Rep)
│   ├── NativeUse.idr    Which locals an expression reads natively
│   ├── CalleeTable.idr  What each callee reads natively per argument, for its callers
│   ├── Pending.idr      Which functions can return a pending closure (trampoline elision)
│   ├── WorkerName.idr   Names of the functions rc2 synthesises
│   ├── Stage.idr        The stages `--directive no<stage>` turns off
│   ├── ForeignSpec.idr  %foreign convention strings (C:/RefC:/RC2:/CExpr:/C__collect_safe:) parser
│   ├── Emit.idr         Mechanical translation from RCExp to C
│   ├── Emit/Util.idr        Name mangling, literal/value emission, closures, FFI type mapping
│   ├── Emit/Foreign.idr     %foreign / %export C wrapper generation and FFI marshalling
│   ├── Emit/ExternRefs.idr  Forward declaration walkers for incremental compilation
│   ├── Pretty.idr       Human-readable RCExp dumper (--directive dumprcexpr)
│   ├── CC.idr           C compiler driver and linker orchestration
│   ├── LibraryFiles.idr The files written next to a static or shared library
│   └── RC2.idr          Backend entry point and codegen pipeline registration
├── support/rc2/       Runtime library (libidris2rc2.a)
├── doc/               Detailed per-pass design notes (see index in AGENT.md)
└── tests/             Regression and benchmark suites
```

### Pipeline Order

The stages in the order `Compiler.RC2.RC2` runs them on a whole program, each linked to its design notes. Most can be turned off with the directive in the last column ([`rc2/doc/directives.md`](rc2/doc/directives.md)); an *opt-in* stage runs only when that directive is given. In incremental mode upstream's CSE (`IncCse`) runs first, and the whole-program stages (shared subtrees, unread constant fields, function dedup) do not run.

| # | Stage | Module | What it does | Directive |
|---|---|---|---|---|
| | **On the named case trees** | | | |
| 1 | [Nat magic](rc2/doc/nat-magic.md) | `NatMagic` | `Data.Nat.isLTE` / `lte` in constant time | `nonatmagic` |
| 2 | [Delay CAFs](rc2/doc/lazy-memoization.md) | `LazyCaf` | A top-level `Delay` becomes a memoized CAF | |
| 3 | [List divert](rc2/doc/list-divert.md) | `ListDivert` | Upstream's two-pass tail-recursive list functions become naive ones TRMC makes one loop | opt-in `listdivert` / `listfuse` |
| 4 | [Inline](rc2/doc/inlining.md) | `InlineCExp` | Whole-program inlining before lambda lifting | `noinline` |
| 5 | [Dead fields](rc2/doc/dead-fields.md) | `DeadFields` | A copy of a function that does not build the result fields its caller does not read | opt-in `deadfields` |
| 6 | [Dead arguments](rc2/doc/dead-args.md) | `DeadArgs` | Unused arguments of `where` functions go | `nodeadargs` |
| 7 | [Arity raise](rc2/doc/world-arity-raising.md) | `ArityRaiseCExp` | A function returning a closure waiting for the world takes the world itself | `noarityraise` |
| 8 | [Declared types](rc2/doc/native-type-inference.md) | `StrictNative` | The native types each function's arguments and result may be held as | `loosenative`; opt-in `strictnative` |
| | **Into `RCExp`** | | | |
| 9 | [Lambda lift + normalize](rc2/doc/lambda-lifting.md) | `RC` (Phase 1), [`ForeignDivert`](rc2/doc/fastpack-fix.md) | Lambda lifting and ANF; a few `%foreign` declarations go to rc2's own | |
| | **Before RC annotation** (`toRCDefs`) | | | |
| 10 | Target OS | `TargetOs` | `prim__os` folds to a constant | `target-os=<name>` |
| 11 | [ConstFold](rc2/doc/const-con-fold.md) | `ConstFold` ([closures](rc2/doc/const-closure-fold.md), [CAFs](rc2/doc/const-caf-fold.md)) | Constant folding to a whole-program fixpoint | `noconstfold`, `noknowncon` |
| 12 | [Push case into tails](rc2/doc/constructor-escape-analysis.md) | `PushCon` | A `case` moves into the tails of the value it scrutinises | `nopushcon` |
| 13 | [Specialization](rc2/doc/speculative-closure-specialization.md) | `SpecClosure` ([dictionaries](rc2/doc/constant-constructor-specialization.md)) | A callee cloned per constant closure or constant dictionary argument | `nospecclosure`, `nospecconstcon` |
| 14 | [Early inline](rc2/doc/inlining.md) | `LateInline`, `PushApply`, `KnownPartial` | Single-caller and tiny callees spliced, then refolded | `noearlyinline`, `notinyinline`, `nopushapply` |
| 15 | [Comparison merge](rc2/doc/native-type-inference.md) | `CmpMerge` | Two nested comparisons of the same operands become one | `nocmpmerge` |
| 16 | [Lazy fold](rc2/doc/lazy-memoization.md) | `LazyFold` | A lazy value forced once becomes a call | |
| 17 | [Arity raise again](rc2/doc/world-arity-raising.md) | `ArityRaise` | Step 7 on what inlining exposed | `noarityraise` |
| 18 | [TRMC](rc2/doc/trmc.md) | `Trmc` | `x :: f xs` recursion becomes a loop filling each cell's hole | `notrmc` |
| 19 | [Closure contexts](rc2/doc/closure-accumulator.md) | `ClosureCtx` | A `c . (y ::)` difference list kept as a chain of cells | `noctx` |
| 20 | [CAF memoization](rc2/doc/caf-memoization.md) | `RC` (`insertMemoize`) | `RMemoize` around a top-level `unsafePerformIO` CAF | |
| 21 | [Shared subtrees](rc2/doc/shared-subtrees.md) | `FunDedup`, `ShareSubtrees` | Repeated subtrees of a function become one new function | `nosharesubtrees` |
| | **RC annotation and after** | | | |
| 22 | [RC annotate](rc2/doc/reuse-analysis.md) | `RC` (Phase 2), `Reuse`, [`ConAltNative`](rc2/doc/con-alt-native.md) | dup/drop/free insertion, constructor reuse, native shadows of fields | `noconaltnative`, `noreusenested` |
| 23 | [Mutual loop](rc2/doc/loop-conversion.md) | `MutualLoop` | Mutually tail-recursive functions merged into one loop | `nomutualloop` |
| 24 | [Loop](rc2/doc/loop-conversion.md) | `Loop` | Self tail calls become `goto`, with loop-invariant parameters pruned | `noloop` |
| 25 | [Late inline](rc2/doc/inlining.md) | `LateInline` | Single-caller callees spliced, loops included | `nolateinline` |
| 26 | [Fold applied closures](rc2/doc/world-arity-raising.md) | `ArityRaise` | A closure built and applied at once becomes a call | `noapplyfold` |
| 27 | [Push case into tails (post-RC)](rc2/doc/constructor-escape-analysis.md) | `PushCon` | Step 12 on what Late inline creates | opt-in `latepushcon` |
| 28 | [Sink](rc2/doc/branch-sinking.md) | `Sink` | A `let` moves into the one branch that reads it (then step 26 again) | `nosink` |
| 29 | [Dual ABI](rc2/doc/dual-abi.md) | `DualABI` ([struct return](rc2/doc/struct-return.md)), [`NullParams`](rc2/doc/null-params.md) | Native workers, struct return, NULL-typed world/erased parameters | `nodualabi`, `nostructreturn`, `noboolret`, `nonullparams`, ... |
| 30 | [Reuse re-check](rc2/doc/reuse-analysis.md) | `Reuse` | Reuse offers DualABI left dead are dropped | `noreuserecheck` |
| 31 | [Forwarder aliases](rc2/doc/fwd-alias.md) | `FwdAlias` | A reference to a function that only forwards goes to its target | `nofwdalias` |
| 32 | [Dead code](rc2/doc/dead-code-elim.md) | `DeadCode` | Whole-program mark-and-sweep | `nodeadcode` |
| 33 | [Push-down](rc2/doc/pushdown.md) | `PushDown` | The dup/drop run before a `case` moves into its branches and cancels | `nopushdown` |
| 34 | Dup merge | `DupMerge` | Several `dup`s of one local become one | `nodupmerge` |
| 35 | [Leaf tail calls](rc2/doc/leaf-tail-calls.md) | `LeafTail` | A tail call outside any tail-call cycle becomes a direct C call | `noleaftail` |
| 36 | [Dead variables](rc2/doc/dead-vars.md) | `DeadVars` | Unused bound locals erased (then step 34's cancellation again) | `nodeadvars` |
| 37 | [Unread constant fields](rc2/doc/dead-fields.md) | `ConstFields` | Fields of constant constructors no alt reads go | `noconstfields` |
| 38 | [Function dedup](rc2/doc/fun-dedup.md) | `FunDedup` | Functions equal up to local numbering become one | `nofundedup` |
| 39 | [Stack constructors](rc2/doc/stack-con.md) | `StackCon` | A constructor that never leaves its function is built in the C frame | `nostackcon` |
| | **Output** | | | |
| 40 | C generation | `Emit` | `RCExp` to C | |
| 41 | C compile and link | `CC` | Runs the C compiler | `nocc` |

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

### 7. C Expressions as `%foreign` Targets (`CExpr:`)
`%foreign "CExpr:abs($1),libc,stdlib.h"` binds a declaration to a C expression or constant (a macro, `O_CREAT`) instead of a function name, so no C shim is needed; `$1`, `$2`, ... are the arguments and are substituted in parentheses. In a declaration with an `Integer` result, `$r` is the GMP out-parameter (`"CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"`), so GMP functions bind without a shim. The header option may list several headers separated by `;` (`fcntl.h;sys/stat.h`; RefC reads it as one name). It has top priority among rc2's tags and other backends ignore it. See [`rc2/doc/ffi-cexpr.md`](rc2/doc/ffi-cexpr.md).

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

Times `rc2/tests/bench/Bench*.idr` compiled with both `idris2-rc2` and upstream `idris2 --cg refc`, reporting wall-clock speedup ratios (`--runs N` sets iterations; `--missing-containers` adds external container benchmarks). Results and methodology are recorded in [`rc2/BENCHMARKS.md`](rc2/BENCHMARKS.md).

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
