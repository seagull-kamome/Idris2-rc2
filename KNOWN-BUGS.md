# Known bugs

Bugs that are still present, in one of two places:

- **the upstream reference toolchain** (the self-built `idris2` from
  `idris2-src/`, kept at upstream `origin/main` by fast-forward merge;
  nixpkgs' `idris2` only bootstraps it -- see `env.sh`/`gen-env.sh`);
- **rc2 itself**, not yet fixed.

Each entry says how rc2 or its tests work around it, so a test run that
hits one doesn't start a fresh investigation. Fixed bugs don't belong
here: their write-ups live in `rc2/doc/` and the git history, and
forward-looking work in `TODO.md`.

If one of these stops reproducing, or a fix lands, remove the entry.

## Upstream reference-toolchain bugs

- **The frontend gives `where` functions unused extra arguments --
  handled in rc2.** Idris2's elaborator lifts a `where` function to the
  top level with every variable of the enclosing clause as an extra
  argument, whether it uses it or not. This is visible in
  `--dumpcases`, before lambda lifting: `Data.List.splitRec` receives
  `sortBy`'s `cmp` and outer `xs` and only passes them to itself.

  Carried through a loop, such an argument holds its value until the
  loop exits. That cost `sort` 23% and 2.36x its allocations.

  rc2 removes these arguments in its own pass,
  `Compiler.RC2.DeadArgs` (`rc2/doc/dead-args.md`, test
  `Test99DeadArgs`), so this needs no further investigation when it
  shows up in a dump. It is off only under
  `--directive nodeadargs` and in incremental compilation.
- **`Test7CastMatrix.idr` can't be diff-checked against real
  `idris2 --cg refc` at all.** Originally because the reference RefC
  support library's `idris2_negate_Double` was typo'd as
  `idris2_nagate_Double`, plus a couple of missing declarations -- **that
  typo is now fixed** in this project's self-built reference toolchain
  (`idris2-src`, confirmed directly: `mathFunctions.h` spells
  `idris2_negate_Double` correctly). But the test still can't be
  compiled by real `idris2 --cg refc`, now for a *different* reason:
  `idris2-src/support/refc/casts.h`'s `idris2_cast_Double_to_Int` is a
  copy-paste of the `Int8` cast (`idris2_mkInt8((int8_t)
  idris2_vp_to_Double(x))` -- wrong helper, wrong width), and there is
  no separate `idris2_cast_Double_to_Int8` defined at all, so a program
  exercising that cast hits an undeclared-function compile error. Net
  effect unchanged: still can't be diff-checked against real refc, just
  a different underlying bug now. Confirmed to be a defect in that
  reference toolchain itself, not rc2 -- `idris2-rc2`'s own build of the
  same file compiles and runs cleanly. Verified instead via a saved
  `.expected` file (manual verification), same as `rc2/tests/
  refc-suite`'s own `Test7CastMatrix`-equivalent handling. See
  `rc2/doc/dual-abi.md`'s own "Verification methodology" item 5 /
  `rc2/doc/reuse-analysis.md`'s item 4 for the original write-up.
- **`refc-suite`'s `basicpatternmatch` test: real RefC itself fails to
  match `Bits32 0x80000000` and the `Int64` min/max boundary literal
  cases**, falling through to the catch-all (flagged `-- FIXME: wont
  work` in upstream Idris2's own test source). rc2 does not have this
  bug -- its `expected` file reflects the *correct* result, which is
  why it doesn't literally match what a naive read of upstream's own
  `expected` would suggest. See `rc2/tests/refc-suite/README.md`.
- **`refc-suite`'s `clock` test: real RefC's own `clockTimeMonotonic`
  isn't actually monotonic** -- it just reuses RefC's second-granularity
  UTC clock (`time()`), so `monotonicStart < monotonicEnd` reads
  `False` for a test run completing within the same wall-clock second.
  rc2 implements its own `System.Clock` via `clock_gettime`
  (nanosecond resolution, genuinely monotonic), so its own `expected`
  intentionally differs from what upstream's `expected` would produce
  under real RefC. See `rc2/tests/refc-suite/README.md` and
  `rc2/BENCHMARKS.md`'s own "本家RefCの`System.Clock`は秒精度" note.
- **Upstream's own `idris_support.h` declares no C prototype for
  `idris2_setenv`/`idris2_unsetenv`, even though `idris_support.c`
  defines both and `System.idr`'s `setEnv`/`unsetEnv` target them
  through that same header** -- a real upstream header/implementation
  mismatch. Not just a harmless warning: confirmed that real
  `idris2 --cg refc` cannot even compile a program calling `setEnv`/
  `unsetEnv` in this project's own reference toolchain (gcc's implicit-
  declaration diagnostic is a hard error there, not a warning as
  originally assumed). rc2 works around it for its own builds by
  declaring both prototypes itself in `rc2/support/rc2/
  idris2rc2_runtime.h` (included ahead of upstream's own
  `idris_support.h`, so the mismatch never reaches the compiler; the
  functions themselves are still the shared library's own, unmodified)
  -- see that file's own comment. `Test42SupportMisc.idr` exercises
  this and is listed in `verify.sh`'s `NO_REFC_DIFF_TESTS` since there's
  no real-RefC output to diff against in the first place. Re-verified
  directly against this project's self-built reference toolchain
  (`idris2-src` at its currently pinned commit): unchanged.
- **Upstream RefC's own `cTypeOfCFType CFString = "char *"` (no
  `const`) still collides with `-Werror`/`-Wdiscarded-qualifiers` on
  any `const char *`-returning C function** (e.g.
  `curl_easy_strerror`). Confirmed directly: `rc2/tests/
  Test47ConstCFStringReturn.idr` cannot be built by real
  `idris2 --cg refc` at all -- it fails with exactly this
  warning-turned-error. rc2 itself no longer has this limitation:
  `Compiler/RC2/Emit/Util.idr`'s `cTypeOfCFType CFString` was changed to
  `"const char *"` (`idris2rc2_mkString` already took `char const *s`,
  so no other codegen change was needed). `Test47ConstCFStringReturn`
  is listed in `verify.sh`'s `NO_REFC_DIFF_TESTS` since there's no
  real-RefC output to diff against for it. Re-verified directly against
  this project's self-built reference toolchain (`idris2-src` at its
  currently pinned commit): unchanged.
- **`Test35NetworkLoopback.idr` can't be diff-checked against real
  `idris2 --cg refc` at all.** Originally because the reference RefC's
  generated code called `idris2_cast_string_to_Integer` (lowercase, via
  `Network.Socket.Data.parseIPv4`'s `Cast String Integer` usage) while
  only `idris2_cast_String_to_Integer` (capital `S`) was actually
  defined -- **that naming mismatch is now fixed** in this project's
  self-built reference toolchain (`idris2-src`, confirmed directly:
  both the generated call site and `support/refc/casts.h`/`casts.c`'s
  own declaration/definition are now consistently lowercase), fixed by
  upstream commit `0781ad1 [refc] Fix casts from String failing to
  compile (#3832)`. But the test still can't be compiled by real
  `idris2 --cg refc`, now for a *different, unrelated* reason: a genuine
  internal inconsistency within `idris2-src` itself, between the
  Idris-level `network` package and its own C runtime implementation --
  `idris2-src/libs/network/Network/FFI.idr`'s own `%foreign` declaration
  of `prim__idrnet_send_bytes` expects a 4-argument C function
  (`idrnet_send_bytes(sockfd, content, nbytes, flags : Bits32)`, i.e. it
  takes a `flags` parameter), but `idris2-src/support/c/idris_net.h`/
  `idris_net.c` still only declare/define the old 3-argument version
  (`int idrnet_send_bytes(int sockfd, void *data, int len)`) with no
  `flags` parameter at all -- confirmed to still be present at
  `idris2-src`'s currently pinned commit, which is current
  `origin/main` HEAD (i.e. not yet fixed upstream as of this writing).
  Entirely an upstream `idris2-src` defect (a same-commit mismatch
  between its own Idris-level API and its own C implementation),
  unrelated to nix packaging and unrelated to rc2. Real
  `idris2 --cg refc` fails to compile any program exercising
  `Network.Socket.sendBytes` (which `Test35NetworkLoopback` does via
  `accept`'s loopback exchange) with an implicit-declaration/argument-
  count error as a result. Verified instead via a saved `.expected` file
  (manual verification), same reasoning as `Test7CastMatrix` above.
  `Test35NetworkLoopback` is listed in `verify.sh`'s `NO_REFC_DIFF_TESTS`
  since there's no real-RefC output to diff against in the first place.
- **Upstream `System.FFI`'s `getField` elaboration doesn't scale to a
  wide `Struct` -- a genuine OOM crash of the compiler itself, not just
  slow.** Discovered in the sibling `idris2-curl` repo while binding
  `curl_version_info_data` (~25 fields) via `Struct`/`getField` for the
  first time (`%cg rc2 externStruct=curl_version_info_data`, this
  repo's own `rc2/doc/directives.md` section 5). Declaring all ~24
  non-array fields in one `Struct "curl_version_info_data" [...]` list
  and reading each via `getField` crashes `idris2 --build
  package.ipkg` outright: `out of memory`, confirmed directly against
  **this project's own self-built reference toolchain**
  (`idris2-src` at its currently pinned commit, via `env.sh`) with a
  `ulimit -v 6000000` (6GB) cap in place specifically to stop it taking
  down the whole machine, which an earlier uncapped attempt already
  had. Confirmed **not** an rc2 bug and **not** codegen-related at
  all: `idris2 --build` only elaborates/type-checks a library `.ipkg`,
  no codegen backend runs at all -- purely upstream `System.FFI`
  `getField`'s own elaboration-time cost, apparently growing very
  badly with the `Struct`'s own field-list length. A 5-field version of
  the same struct (`version`/`version_num`/`host`/`features`/
  `ssl_version`) compiles fine; the real threshold between 5 and 24 was
  not bisected, and a smaller synthetic repro (24 same-typed `Int`
  fields, no `AnyPtr`/`String` mix, no external struct/header
  involved) did NOT reproduce the crash -- so field *count* alone isn't
  the whole story; something about the real binding's specific shape
  (mixed field types, `ptrToString` on several of them, or the
  surrounding package's own larger elaboration context) also matters,
  not yet isolated further. See `idris2-curl`'s own
  `doc/version-info-struct.md` ("`getField` doesn't scale to a wide
  struct") for the full investigation -- that repo settled for the
  5-field binding rather than chasing this further. Nothing to fix here
  in rc2 itself (this never reaches rc2's own compiler at all), but
  worth knowing before designing any future `Struct` binding with more
  than a handful of fields, rc2-targeted or not.
- **A failed C compile still exits 0, with no "Compilation failed".**
  `idris2-rc2 --cg rc2 -o prog Prog.idr` whose generated C fails in gcc
  (e.g. a `%foreign "C:no_such_function"`) prints gcc's errors, writes
  no executable, and exits 0. Real `idris2 --cg refc` does the same. The
  cause is the frontend, not the backend: rc2's `compileExpr` returns
  `Nothing` (`rc2/src/Compiler/RC2/RC2.idr`, `compileExprWhole`) and
  `compileExp` turns that into `CompilationFailed`
  (`idris2-src/src/Idris/REPL.idr`), but `-o`'s `postOptions` discards
  it with `ignore $ compileExp ...` (`idris2-src/src/Idris/SetOptions.idr`),
  and so does an ipkg build's executable step
  (`idris2-src/src/Idris/Package.idr`). A script driving the compiler
  must therefore check that the executable exists rather than trust the
  exit code -- `rc2/tests/verify.sh` does (`[ -x ... ]`). Found
  2026-09-27 through idris2-curl's `verify.sh`, which checked the exit
  code and so reported an rc2 gcc failure as "no such file" at run
  time.

## rc2: deep non-tail recursion overflows the C stack (Chez doesn't)

rc2 runs Idris code on the C stack (8 MB by default). Chez grows its
stack on demand, so the same programs run to completion there. The
crash is a stack overflow, not a miscompile: every size that fits
returns the right result.

TRMC (`rc2/doc/trmc.md`, phase 1), the difference-list rewrite
(`rc2/doc/closure-accumulator.md`) and a non-recursive
`idris2rc2_teardown` for long lists (`Test96TeardownDeep`) cover
`mergeBy`, `[1 .. n]`, `sortBy`'s `splitRec` and `Data.List.sort`: all
four run at 4M elements with `ulimit -s` 8192 (measured 2026-09-26).
Chez sorts a 1M list in 1.23s; rc2 takes 4.17s.

Any non-tail recursion none of these covers still overflows at a large
enough depth:
- mutual recursion, and sites filling different fields (`TODO.md`,
  TRMC phases 2-4);
- continuation-passing traversals and other closure chains
  (`TODO.md`, "closure-valued loop parameters, beyond difference
  lists").
