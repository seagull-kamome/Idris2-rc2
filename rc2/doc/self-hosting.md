# Self-hosting: building the compiler without Chez Scheme

Status: stages 1 and 2 are done as experiments (`idris2-rc2-norepl` is built by
rc2, and builds the libraries, type-checks the compiler's API package, and builds
itself, with the same result as the Chez-built compiler on all of that). On the 81
programs of `rc2/tests` it gives the same C as the Chez-built compiler, except for
the notation of float literals (finding 9). The seed, `--install` and the speed are
open. This document keeps what was found, and the design for the rest.

Commands: `rc2/tests/selfhost.sh` (see "Reproducing"). The driver that makes it
possible is described in `norepl.md`.

## What "without Chez" means

Today the toolchain is built like this:

```
nixpkgs idris2 (Chez)  ->  idris2 (Chez)   builds   prelude, base, ..., idris2api, rc2, rc2base ...
```

`idris2-rc2`, the compiler that users run, is itself a Chez program: the
upstream `idris2` library (`idris2api`) is compiled by Chez, and `idris2 --build
rc2.ipkg` runs Chez to link it. The goal is a toolchain where, after a seed, no
Chez Scheme is needed: the compiler is a C program made by rc2, and everything it
needs (the `.ttc` files of the libraries, the runtime) is made by that compiler or by a
C compiler.

## Where Chez was used

1. **The compiler's executable.** `idris2-rc2` is `idris2.so` for Chez.
2. **The `.ttc` files** of `prelude`, `base`, `linear`, `network`, `contrib`,
   `test`, of the compiler's API package (`idris2api`) and of `rc2`, `rc2base`
   and the others: written by the Chez-built `idris2`.
3. **Code in the compiler that calls Chez**: the Scheme evaluator of the REPL
   (`Core.SchemeEval`, through the 29 `%foreign "scheme:..."` declarations of
   `Libraries.Utils.Scheme`). Nothing else in `idris2api` or in the libraries needed
   Chez to build; `Libraries.Data.String.Iterator` and the others have a `RefC:`
   implementation, which rc2 uses.
4. **The first compiler** (nixpkgs' `idris2`), once.

Not Chez: `libidris2_support` (C, from `idris2-src/support/c`) and the rc2 runtime.

## What was found

1. **The REPL pulls Chez into the binary.** `Idris.Package.processPackage`
   (`--build`, `--install`, ...) reaches `repl` through a private `runRepl`; the
   REPL reaches `process`, whose `Scheme` evaluation mode is `Core.SchemeEval`.
   Closing the command-line ways to the REPL (`NoRepl.Driver`) did not remove
   it from the binary, so the Chez-only declarations are still linked.
2. **`%foreign_impl` can stand in for them.** It also works for the private
   names (`prim_isNumber`, ...). `NoRepl.SchemeStubs` gives the 29 declarations a body that stops
   the program; a batch compile never calls them. (`prim__gc` of `Idris.ProcessIdr`,
   `scheme:collect`, needed nothing: it is not reached.)
3. **rc2 did not know `ForeignObj`** (`CFForeignObj`), the type of those
   declarations. It is passed through like `CFUser` now.
4. **`rc2.ipkg` did not list three modules** (`Compiler.RC2.Types`, `Sink`,
   `DeadVars`). `idris2 --install` therefore installed an incomplete `rc2`
   package, and `depends = rc2` only worked inside `rc2/`, where `build/` has the
   rest. Listed now.
5. **Compilers built by Chez and by rc2 agree.**
   - `.ttc` of `prelude` (14 files), `base` (136), `linear` (14), `network` (5),
     `contrib` (103), `test` (1) and `idris2api` (292): 565 of 565 byte-identical,
     built with the same options. (Comparing with the installed ones, which are
     built with `IDRIS2_INC_CGS`, is not meaningful: none is identical.)
   - The C of `Hello`, `Test149StrLiteralFold` and `Test87SpecConstCon` is
     identical. `Test112Numeric` differs in two lines: a `Double` literal is
     printed by the rc2 runtime (`4611686018427388000.0`) and by Chez
     (`4.611686018427388e18`), the same value.
   - **Fixed point**: `idris2-rc2-norepl` built by itself gives the same 114 MB C
     file, byte for byte. This says the two compilers agree on that input; it does not
     say they agree on every program (finding 9 was found by comparing more).
6. **Size and time of the build.** The C of `idris2-rc2-norepl` is 114 MB
   (1.69 million lines; 9.3 MB with gzip, 5.8 MB with xz), the executable 15 MB.
   The Chez-built rc2 takes 75 s to produce the C; the C compiler (`-O2`) takes
   about 9 more minutes, on one core.
7. **The rc2-built compiler is about 1.7 times as slow in time as the Chez-built
   one on large builds** (1.65 for `base`; 1.35 for the short `prelude` build), and
   executes about 2.1 times as many instructions.

   | work | Chez-built | rc2-built | ratio |
   |---|---|---|---|
   | `base` (136 modules), 2026-11 | 52.4 s | 86.7 s | 1.65 |
   | `base`, type-checking only (the `Elaborating` times) | 44.3 s | 74.3 s | 1.68 |
   | `prelude` | 5.1 s | 6.9 s | 1.35 |
   | `contrib` (103), earlier | 29.5 s | 62.9 s | 2.1 |
   | `linear`, `network`, `test`, earlier | 6.7 s | 10.3 s | 1.5 |
   | `idris2api` type-check (292), earlier | 403 s | 894 s | 2.2 |
   | `libs/control-async` type-check (11), earlier | 4.9 s | 8.2 s | 1.7 |

   The rows marked "earlier" are from before the speed-ups listed below (the older
   `base` row said 109.9 s, ratio 2.1); the `idris2api` row ran next to another
   build on the same machine; the others alone, one run each.
   Compiling a small program takes about the same time with both (the C compiler is most of it).

   - **No module is an outlier.** For the 136 modules of `base` the ratio of the
     `Elaborating` times lies between 1.6 and 2.1 (median 1.69 for the 20 modules
     that take over 0.5 s in the Chez-built compiler). A module that does almost
     nothing takes 0.08 s against 0.05 s, the same ratio.
   - **Why `prelude` may look better.** Checking one module of three lines executes
     3.44 G instructions in the Chez-built compiler and 2.38 G in the rc2-built one
     (callgrind). That fixed cost of the Chez-built compiler is a larger share of
     a short run such as the build of `prelude`, and may explain part of its better
     ratio. Not measured further.
   - **Where a small check goes in the rc2-built compiler.** 64% of those 2.38 G
     instructions read the `.ttc` of `prelude` (`readFromTTC`, `fromBuf`), which
     builds many small objects.
   - **Outside type-checking.** In the build of `base` it is 14% of the time in the
     rc2-built compiler (12.4 s of 86.7 s) and 15% in the Chez-built one (8.1 s of
     52.4 s).

   With the component rule of `leaf-tail-calls.md` (which replaced its leaf rule),
   building `libs/prelude` executes 36.94 G instructions in the rc2-built compiler
   instead of 39.14 G, against 17.28 G in the Chez-built one (callgrind), so about
   2.1 times as many instructions. Building `idris2-rc2-norepl`
   (`rc2-norepl.ipkg`, C compilation included) takes 10 min 3 s with the
   Chez-built compiler and 12 min 18 s with the rc2-built one, one run each.
   In the callgrind profile of that build, `malloc`/`free` take 27% of the
   instructions, the reference counts (`dup`, `drop`, `teardown`) 26% and the
   allocation wrappers 8%, about 60% for memory management together. The top
   entries are `idris2rc2_teardown` 8.9%, `idris2rc2_drop` 8.8%, `free` 8.3%,
   `malloc` 7.1% and `idris2rc2_dup` 6.8%; no function of the compiler itself has
   more than 1.4%.

   What was tried to speed this build up, with the effect (measured on `libs/prelude`
   built by the rc2-built compiler, unless the cell says otherwise):

   | change | instructions | time | kept |
   |---|---|---|---|
   | tail calls out of a cycle-free callee set made direct (`leaf-tail-calls.md`) | -5.6% | build of `rc2-norepl` by the Chez-built compiler -7% | yes |
   | `let x = <constant>` and its `dup`/`drop` removed (`dead-vars.md`) | -0.004% | | yes (the IR is smaller) |
   | scratch `int cmp_N` / `int64_t tmp_N` of a condition removed | not measured (`gcc` should fold them) | | yes (4,041 lines of C fewer) |
   | preloaded `mimalloc` | | -13% (`prelude`), -12% (`base`) | no (a dependency) |
   | reuse a constructor cell for another constructor of the same size | -0.45% | | no (gain too small) |
   | `dup`/`drop` fast path forced inline (`always_inline`) | -7.1% | -5% | no (build of `rc2-norepl` 10 -> 40 min, executable 15 -> 38 MB) |
   | only the NULL/immediate test of `dup`/`drop` inline | +3.4% | +8% | no (slower) |

   Stack-allocating constructors that are only borrowed would reach few of them.
   Counted statically on the IR of the compiler, not at run time: of 34,383
   constructors bound by `let`, at most 7.6% could be stack-allocated if every
   argument of a non-tail call could be borrowed, and 1.4% with the parameters that
   can be borrowed today (`borrow-inference.md`). `teardown` takes about 47
   instructions per freed object (a call frees a whole structure, so its cost
   follows the number of objects). `TODO.md` ("a small-object allocator") keeps the
   open item.

   The self-build is an experiment, not a replacement for the Chez-built compiler.
8. **What works with the rc2-built compiler** (tested): `-o`, `--check`, `--typecheck` and `--build` of
   packages (libraries and an executable), `--version`, `--help`. `--exec` was only run
   with the Chez-built `idris2-rc2-norepl`. **Not tested**: `--install`, `--mkdoc`,
   `--clean`, `--incremental`.

9. **The rc2-built compiler cut String constants at a NUL (fixed).** Found by compiling the
   81 programs of `rc2/tests` with both compilers and comparing the C (77 identical at
   first; 78 identical, 3 differing only in float notation and none otherwise after the
   fix; see "Reproducing", `diff`):
   - `Test112Numeric`, `Test168NumericEdge/DoubleString` and `Test168NumericEdge/DoubleToIntWrap` differ only in
     the notation of `Double` literals (and in the names of the constants made from
     them): `1e-6` and `0.000001`, `9.007199254740992e15` and `9007199254740992.0`.
     The values are the same (checked on 19 literals with a float parser).
   - `Test169Strings/StringNul` differs in 1190 lines: `"ab\x00""1cd"` became `"ab"`.
     Minimal case: `printLn (Prelude.String.length "ab\NUL1cd")` prints 6 when the
     program is compiled by the Chez-built compiler and 2 by the rc2-built one.
   - Cause: `Data.Buffer.stringByteLength`, `prim__setString` and `prim__getString`
     are `RefC:` foreigns on a `char *`, which rc2 does not divert as it does `fastPack`
     and the others, and the compiler's `.ttc` code (`TTC String`, `Core.Binary.Prims`)
     uses exactly these three. Elaboration and the normaliser are right
     (`length "ab\NUL1cd" = 6` is accepted by both compilers); the string is lost
     between elaboration and code generation. (`Libraries.Data.String.Iterator`, which
     only `Core.Hash` uses, was another `char *` case that was not diverted.)
   - The Chez-built compiler has a bug here too: it prints the denormal `5e-324` as
     `5e-324|1` (Chez's notation), which is not C. The rc2-built one is right.
   - Fix: the three `Data.Buffer` functions (and `Libraries.Data.String.Iterator`) are
     replaced by rc2's own length-aware ones when the program is turned into `RCDef`s
     (`Compiler/RC2/ForeignDivert.idr`). What is replaced and why is in
     `fastpack-fix.md`, "What is replaced, and why". `Test169Strings/StringNul` covers it.

## Design

### The chain

```
seed        ->  stage1                 ->  stage2 (the proof)
(C or Chez)     idris2-rc2-norepl          stage1 builds libs + idris2api + itself;
                built by rc2               its C must equal the C of stage1
```

- **stage1** is `idris2-rc2-norepl` built by rc2 from `rc2-norepl.ipkg`. It
  needs the `.ttc` of `rc2` and its dependencies, so the first time they come from
  the seed toolchain.
- **libs**: stage1 builds `prelude`, `base`, `linear`, `network`, `contrib`,
  `test` (the order and the `IDRIS2_PATH` of `idris2-src/Makefile`), then the API
  package, `rc2` and `rc2base`. With these in a new prefix, the old toolchain is not needed.
- **fixed point**: stage1 builds `rc2-norepl.ipkg`; the C file must equal stage1's.
  This is the check that the toolchain reproduces itself.

### The seed

Three ways to get the first stage1, in the order of preference:

1. **The C file of stage1**, shipped with a release (5.8 MB with xz; not in git).
   A C compiler, `libidris2_support` and the rc2 runtime are enough to make the
   compiler. The fixed point check says whether the seed is the C the
   current sources give.
2. **Chez** (what `selfhost.sh stage1` does): `idris2 --build rc2.ipkg`, then rc2
   builds `rc2-norepl.ipkg`. It stays the way to start from the sources.
3. **nixpkgs' `idris2`**: the current first step of the build (README).

### What the toolchain contains

The target is `install/idris2-0.8.0/` with the `.ttc` of the libraries and of the
API package, `support/` (the C support library and the rc2 runtime) and the packages
`rc2`, `rc2base`, ...; and `bin/idris2-rc2-norepl`. Nothing in it should need Chez once
the `.ttc` come from stage1, and the `idris2` of upstream (with its REPL, built by
Chez) would no longer be needed to build or to install. Nobody has made such a prefix
yet: `--install` is the first open point.

## Open points, in the order to do them

1. **`--install` and the other package commands with stage1.** They write the
   prefix (`.ttc`, `.ttm`, the support files of `postinstall`). Test: a prefix built
   by stage1 alone, then `rc2/tests/verify.sh` and the verify scripts of
   `libs/*` with it.
2. **A seed release** (the C file, how it is made and checked), and a check in
   `gen-env.sh`/`env.sh` that does not ask for Chez when stage1 is there.
3. **Speed.** About 1.7 times in time and 2.1 times in instructions (finding 7); the
   number to bring down (target: not more than 1.2). The profile is taken: about 60%
   of the instructions are memory management and no function stands out. What is
   left is to do less of it (the table in finding 7 lists what was tried) or to make
   each operation cheaper (`TODO.md`, "a small-object allocator"). The compiler is
   also the best large program for the optimisations of rc2.
4. **Build time.** 9 minutes of C compiler on one core. Per-module C (`--inc rc2`),
   or a C file cut in several translation units, would let `make -j` work; `-O1` for
   the cold code is the other lever.
5. **The REPL out of the binary** (not needed for the above): needs a copy of
   `processPackage`, about 1100 lines of `Idris/Package.idr`.
6. **Keeping up with upstream**: `NoRepl.Driver` and `SchemeStubs` copy and
   stub upstream code. A script that compares the copied functions with the new
   upstream sources, and one that lists the `scheme:` declarations without a stub,
   should run when `idris2-src` is updated.

## Profile of the self-built compiler (2026-11-04)

`perf record -e cpu-clock` (user space; `perf_event_paranoid` is 2, so no kernel samples) on the
`-O2` self-built `idris2-rc2`, building `rc2.ipkg` in a scratch copy (`IDRIS2_CC=true --cg rc2
--build rc2.ipkg`, so the C compiler is skipped). `perf` came from `nix-shell -p perf`. The generated
C is built without frame pointers, so a call graph needs `--call-graph dwarf,12288`, which cuts deep
stacks short: what it says about the callers of a leaf is only partly complete.

Times without `perf` (`.ttc` already built, so the code generation alone): 2m47s with the
self-built compiler, 1m20s with the Chez-built one. The build from scratch (type check and code
generation) with the self-built compiler is 4m35s.

Type check alone (`--typecheck rc2.ipkg`, 109 s, flat profile). Memory management is about 56% of
the samples: `idris2rc2_teardown` 10%, `dup` 8%, `drop` 7%, `malloc` and `free` 15%, glibc's
internal functions (`_int_malloc`, the chunk functions) 12%, `newConstructor` and `alloc` 4%.
By inclusive time (dwarf call graph):
- `TTImp.Elab.Check.check` 27%, `checkApp` 22%, `tryError`/`handle` 13-23%,
  `solveConstraints` 11%, `AutoSearch.searchType` 12%, `readModule` 13%;
- `Core.Directory.nsToPath` 8.2% (`Libraries.Utils.Path.parse` 8%) and
  `Compiler.Inline.compileAndInlineAll` 12.7%: functions of upstream Idris2 that rc2 does not change;
- `Name.compare`, `UserName.compare`, `memcmp` and `NameMap.lookup` together 5-9%; the callers of
  `dup` include `Name.compare` (3.8% of the samples), which `dup`s the fields of both names.

Code generation, `--timing 2`, self-built compiler against the Chez-built one:

| pass | self-built | Chez-built |
|---|---|---|
| early inline | 68.4 s of 167 s | 31.8 s of 80.5 s |
| late inline | 10.9 s | 5.2 s |
| speculative specialization | 9.5 s | 4.2 s |
| DualABI | 7.6 s | 3.6 s |
| RC annotate + Reuse + ConAltNative | 5.5 s | not timed |
| function dedup | 4.2 s | 1.5 s |

The passes are 2.1 to 2.3 times slower, function dedup 2.8 times; the early inline is about 40% of
the whole run in both. `--timing 3` (Chez-built): 9 outer iterations of the early inline, the
rounds adding up to 23.5 s. Across the early and late inline, `LI prune` takes 8.0 s over 28 rounds,
`LI analyse` 5.3 s over 29 and `LI defOf` 0.9 s: about 0.5 s per round on average, however few
functions a round splices (the first two rounds start from nothing and weigh more).
`TODO.md` ("Compile time: refactoring ideas, 2026-09-29") records that the analysis already resumes
from the previous round (`inlining.md`, "Rounds are incremental"), and that making the pruning
incremental was weighed against its complexity and left, on an estimate of 0.3 s for idris2-lsp.
The sums above are for another program and for both inline stages; the decision stands.

In the code generation `Prelude.Types.List.reverseOnto` is 3.8% of the samples; in the (cut) call
graph its callers are `tailRecAppend` and `RC2.lowerProgram`.

## Reproducing

```sh
cd rc2
./tests/selfhost.sh stage1   # about 10 minutes
./tests/selfhost.sh libs     # 3 to 4 minutes
./tests/selfhost.sh api      # about 15 minutes
./tests/selfhost.sh fixed    # about 12 minutes
./tests/selfhost.sh diff     # about 10 minutes: compiles rc2/tests with both compilers
```

`diff` needs the Chez-built `idris2-rc2` (step 1 of `stage1` makes it) and `stage1`. It
lists the programs whose C differs other than in float notation, and fails if there is one.

Except for what `stage1` writes (`idris2 --install rc2.ipkg` updates the `rc2` package in
`install/`, and `rc2/build/exec` gets the new executables), everything is built under
`rc2/build/selfhost` (git-ignored). The comparison with the
Chez-built compiler in "What was found" was made by running the same commands
with the Chez-built `idris2-rc2-norepl` (`idris2 --build rc2-norepl.ipkg`) in a second
directory, and comparing the `.ttc` with `cmp`.
