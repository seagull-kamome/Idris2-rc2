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
   rc2 takes 75 s to produce the C; the C compiler (`-O2`) takes about 9 more
   minutes, on one core.
7. **The rc2-built compiler is about twice as slow as the Chez-built one**, on
   the same work:

   | work | Chez-built | rc2-built | ratio |
   |---|---|---|---|
   | `prelude` | 5.1 s | 8.0 s | 1.6 |
   | `base` (136 modules) | 52.4 s | 109.9 s | 2.1 |
   | `contrib` (103) | 29.5 s | 62.9 s | 2.1 |
   | `linear`, `network`, `test` | 6.7 s | 10.3 s | 1.5 |
   | `idris2api` type-check (292) | 403 s | 894 s | 2.2 |
   | `libs/control-async` type-check (11) | 4.9 s | 8.2 s | 1.7 |

   The `idris2api` row ran next to another build on the same machine; the others alone.
   Compiling a small program takes about the same time with both (the C compiler is most of it).

   Later measurements, in instructions and not in time, after the component rule
   of `leaf-tail-calls.md` replaced its leaf rule (the table above is from
   before): building `libs/prelude` executes 39.14 G instructions with the
   rc2-built compiler before that change and 36.94 G after it, against 17.28 G
   with the Chez-built one (callgrind), so about 2.1 times. Building `idris2-rc2-norepl`
   (`rc2-norepl.ipkg`, C compilation included) takes 10 min 3 s with the
   Chez-built compiler and 12 min 18 s with the rc2-built one, one run each.
   In that callgrind profile about 60% of the instructions are memory
   management (allocation, reference counts), which `TODO.md` ("a small-object
   allocator") and a preloaded `mimalloc` (-13% in time on `prelude`, -12% on
   `base`) address; the self-build is an experiment, not a
   replacement for the Chez-built compiler.
8. **What works with the rc2-built compiler** (tested): `-o`, `--check`, `--typecheck` and `--build` of
   packages (libraries and an executable), `--version`, `--help`. `--exec` was only run
   with the Chez-built `idris2-rc2-norepl`. **Not tested**: `--install`, `--mkdoc`,
   `--clean`, `--incremental`.

9. **The rc2-built compiler cut String constants at a NUL (fixed).** Found by compiling the
   81 programs of `rc2/tests` with both compilers and comparing the C (77 identical at
   first; 78 identical, 3 differing only in float notation and none otherwise after the
   fix; see "Reproducing", `diff`):
   - `Test112Numeric`, `Test83DoubleString` and `Test145DoubleToIntWrap` differ only in
     the notation of `Double` literals (and in the names of the constants made from
     them): `1e-6` and `0.000001`, `9.007199254740992e15` and `9007199254740992.0`.
     The values are the same (checked on 19 literals with a float parser).
   - `Test124StringNul` differs in 1190 lines: `"ab\x00""1cd"` became `"ab"`.
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
     `fastpack-fix.md`, "What is replaced, and why". `Test124StringNul` covers it.

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
3. **Speed.** The factor of two is the number to bring down (target: not more
   than 1.2). Start with a profile (`callgrind`) of `base` built by stage1, to see
   whether it is the work of the type checker (`Integer`/`Nat`, `String`, maps), the
   closures, or the reference counts. The compiler is also the best large program for the
   optimisations of rc2.
4. **Build time.** 9 minutes of C compiler on one core. Per-module C (`--inc rc2`),
   or a C file cut in several translation units, would let `make -j` work; `-O1` for
   the cold code is the other lever.
5. **The REPL out of the binary** (not needed for the above): needs a copy of
   `processPackage`, about 1100 lines of `Idris/Package.idr`.
6. **Keeping up with upstream**: `NoRepl.Driver` and `SchemeStubs` copy and
   stub upstream code. A script that compares the copied functions with the new
   upstream sources, and one that lists the `scheme:` declarations without a stub,
   should run when `idris2-src` is updated.

## Reproducing

```sh
cd rc2
./tests/selfhost.sh stage1   # about 10 minutes
./tests/selfhost.sh libs     # about 4 minutes
./tests/selfhost.sh api      # about 15 minutes
./tests/selfhost.sh fixed    # about 10 minutes
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
