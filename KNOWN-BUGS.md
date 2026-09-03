# Known bugs and quirks (not going to surprise you again)

Confirmed, already-investigated issues that show up while testing rc2
but are **not** rc2 regressions to chase down again -- either a defect
in this project's own *reference* toolchain (a self-built upstream
`idris2` compiled from `idris2-src/`, pinned at a specific commit and
kept up to date by fast-forward merge from `origin/main`; nixpkgs'
`idris2` package is used only for that compiler's own one-time
bootstrap, not as the reference itself -- see `env.sh`/`gen-env.sh`),
an already-understood quirk of the test file itself, or a pre-existing
gap confirmed unrelated to whatever work is in progress when it's
rediscovered. Kept separate from `TODO.md` (forward-looking gaps/future
work) and `rc2/tests/refc-suite/README.md` (bugs found *and fixed*
during that port) specifically so re-running the test suite doesn't
trigger a fresh investigation of something already closed out.

If one of these stops reproducing, or a fix lands, update or remove the
entry rather than leaving it stale.

## Real reference-installation bugs (not rc2 bugs)

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
  `Compiler/RC2/EmitUtil.idr`'s `cTypeOfCFType CFString` was changed to
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

## Retired: `--directive noreuse` no longer exists

`--directive noreuse` used to let `Compiler.RC2.RC2.idr`'s `toRCDefs`
skip `Compiler.RC2.Reuse` (constructor reuse-in-place), for the same
kind of A/B isolation `noloop`/`noconaltnative`/etc. still provide. But
disabling it reliably corrupted the heap (`malloc(): unaligned tcache
chunk detected`) in 11 of 17 smoke tests -- some later pass apparently
assumes `Reuse` already ran, but which pass and what invariant it
relies on was never root-caused. Rather than leave that footgun
sitting in `verify.sh --directive`, the ability to disable `Reuse` this
way was removed outright: `toRCDefs` now always runs `applyReuse`
unconditionally, and `"noreuse"` is gone from the `disabledStages`
allow-list. Passing `--directive noreuse` today is a harmless no-op,
same as any other unrecognized directive string. If a way to disable
`Reuse` is ever reintroduced, expect this same corruption to resurface
until the actual invariant is found.

## Retired: FFI worker synthesis (Stage 3c) no longer has its own argument-count limit

`Compiler.RC2.DualABI`'s Stage 3c FFI worker synthesis (`ffiWorkerTable`/
`ffiEntry`) used to exclude any `%foreign` declaration with more than
`Compiler.RC2.EmitUtil.MaxExtractFunArgs` (20) parameters
unconditionally (`if length fargs > MaxExtractFunArgs then pure []
else ...`), before ever reaching the natively-eligible-position check
that actually decides whether synthesizing a worker is worth it at
all. This mirrored Stage 3a's own former blanket exclusion on ordinary
functions (see `rc2/doc/dual-abi.md`'s history items 6-8) -- but unlike
Stage 3a's, which got investigated and properly narrowed down to just
the one thing it actually needed to guard against, Stage 3c's own copy
was carried over unexamined, left in place "to be safe" (see `TODO.md`'s
own former "Scope: FFI worker synthesis (Stage 3c) keeps its own
20-argument limit" entry, now closed out and removed).

Investigated and confirmed unnecessary, then removed outright -- the
cutoff is gone from `ffiEntry`, which now always proceeds to the
natively-eligible-position check (`if not (any anyNative argReps) &&
not (anyNative retRep) then pure [] else ...`) regardless of a
declaration's own arity: (1) `emitFFIWorker` (`Compiler.RC2.Emit`) has
no width-dependent `var_arglist[]` fallback at all -- `declareParam`
always emits individually-typed positional parameters, so the bug
Stage 3a's own item 6 fixed for ordinary workers (`createCFunctions`'s
`MkRCFun` case falling back to `var_arglist[]` past the width limit)
never existed on this path in the first place; (2) an FFI worker is
never stored in a `Closure` -- closure construction always uses the
wrapper's own original name, and the worker's own name is reachable
only via a direct, statically-named `RAppNameRep` call, so it never
needs to satisfy `support/rc2/runtime.c`'s closure-dispatch
function-pointer convention (`IDRIS2RC2_FUN0`..`FUN20`/`FUNSTAR`) that
the width limit existed to protect; (3) `extractValue`/`packCFType`/
`nativeCType` are all purely positional, arity-independent transforms,
nothing in them changes shape past 20 parameters. Verified with a new
regression test, now `rc2/tests/Test33WideDualABIWorker.idr`'s own
`prim__wide` (formerly a separate `Test48WideFFIDualABIWorker.idr`,
merged in): a 15-parameter `%foreign` declaration -- 12 native-eligible
`Int`s + 3 `Boxed` `String`s, a "mostly native, some Boxed" shape but
past what the old limit would have excluded, called fully saturated
from `main` so Stage 4's own
call-site rewriting fires): the generated C was inspected by hand and
shows `idris2rc2_ffiworker_Main_prim__wide_0` declared with 12
individually-typed `int64_t` parameters plus 3 `IDRIS2RC2_Value *`
parameters (no `var_arglist[]` anywhere), with `main`'s own call site
calling the worker directly (confirming Stage 4's rewrite fired).
`verify.sh --regen-expected` (full suite, 85/85) and
`refc-suite/run.sh` (19/19) both pass; `valgrind --leak-check=full`
reports `0 bytes definitely lost` for this test (registered in
`verify.sh`'s `LEAK_SENSITIVE_TESTS`). See `rc2/doc/dual-abi.md`'s
history item 9 for the full write-up.

## Retired: FFI worker synthesis (Stage 3c) no longer emits a standalone worker C function at all

The entry immediately above ("Retired: FFI worker synthesis (Stage 3c)
no longer has its own argument-count limit") describes a former design
where `Compiler.RC2.DualABI`'s `ffiWorkerTable` caused
`Compiler.RC2.Emit` to emit a *second*, native-signature C function
(`idris2rc2_ffiworker_*`) alongside a `%foreign` declaration's own
always-Boxed wrapper, with `Compiler.RC2.DualABI`'s Stage 4
(`applyCallSiteRewriteBody`) redirecting eligible call sites to call it
directly. That entry's own argument-count-limit fix is still accurate
history for the design *as it existed then* -- but the mechanism it
describes (a separate worker function existing at all) is itself now
superseded by this entry: there is no longer any standalone
`idris2rc2_ffiworker_*` C function anywhere in generated output, for
any `%foreign` declaration, regardless of arity.

Replaced with direct call-site inlining: Stage 4 itself is completely
unchanged (it still produces an `RAppNameRep` pointing at the
synthesized worker *name*, exactly as before -- the argument-count-
limit fix above still applies to that unchanged step). A new pass,
`inlineFFIWorkers` (`Compiler.RC2.DualABI`, described in that module's
own comments as Stage 5, run immediately after Stage 4), walks the
whole program and replaces every `RAppNameRep` pointing at an FFI
worker name with a new `RAppFFIInline` IR node (`Compiler.RC2.RCExp`)
instead, reusing Stage 4's own `postDrop`/`args` decisions verbatim (no
recomputation needed -- see that node's own doc comment for why this is
always safe). `Compiler.RC2.Emit`'s own `emitFFIWorker` and
`Compiler.RC2.EmitUtil`'s own `FFIWorkers` ref (both mentioned in the
entry above) are deleted outright; a new `emitAppFFIInlineInto` (plus a
dedicated `RAppFFIInline` case on `emitNativeValue`, for whenever an
enclosing `RLet` promotes the call's own result straight to native) do
the marshalling+call+return inline at each call site instead, sharing a
`ffiRawCall`/`ffiArgMarshal` helper pair.

Verified with a new regression test, now `rc2/tests/Test27FFIDualABI.idr`'s
own `inlineLoop`/`prim__add50`/etc. (formerly a separate
`Test50FFIInlineNoWorker.idr`, merged in; registered in `verify.sh`'s
`LEAK_SENSITIVE_TESTS`): full
`verify.sh`/`refc-suite/run.sh` (19/19) pass, `valgrind --leak-check=full`
reports `0 bytes definitely lost`, and -- by hand -- `grep -c
idris2rc2_ffiworker_` against the generated `.c` for
`Test27FFIDualABI`/`Test33WideDualABIWorker`
all return `0`, confirming no standalone FFI worker C function is
emitted anywhere any more. See `rc2/doc/dual-abi.md`'s "Stage 5: FFI-
inline call splicing" section for the full design writeup, including
the re-measured ~20% performance win on `Test27FFIDualABI.idr`'s own
loop benchmark (up slightly from the former design's own ~18%, i.e. no
regression from the rewrite).

## Retired: `ROp`'s Boxed `Integer` arithmetic never reused a dying/unique operand's own heap allocation

`RCon`'s own `annotate` case (`Compiler.RC2.RC`) already used a
strictly cheaper ownership convention than `ROp`'s -- `wrapDups`/
`splitBorrows`, no separate `postDrop` at all, transferring a dying
argument's ownership straight into the new constructor instead of
dropping it -- exactly the shape `Compiler.RC2.Reuse`'s reuse-in-place
pass exploits for constructor destructure/rebuild. `ROp` (Boxed
arithmetic, e.g. `Integer` addition backed by GMP `mpz_t`) instead
always emitted an explicit compiler-side `idris2rc2_drop` after the
call regardless of uniqueness, so a Boxed numeric primitive always
allocated fresh even when an operand was dying and uniquely referenced
right at that call (see `TODO.md`'s own former "Performance: `ROp`'s
Boxed arithmetic never reuses a dying/unique operand's own heap
allocation" entry, now closed out and removed).

Investigated and implemented: unlike `RCon` reuse, which needed a
dedicated IR pass (`Compiler.RC2.Reuse`, its own `RReuseOffer` node) to
bridge an "offer" and a "claim" occurring in two different places in
the IR, `ROp` consumes its operand(s) and produces its result in the
same C statement (one runtime call) -- there is no gap to bridge, so
this needed **zero IR changes**: `RCExp.idr`'s `ROp` node, `RC.idr`'s
`annotate` case, and `Compiler.RC2.Reuse` itself are all untouched. The
entire change is confined to `rc2/support/rc2/numeric.h` (10 Boxed
`Integer` primitives -- `add`/`sub`/`mul`/`mod`/`negate`/`and`/`or`/
`xor`/`shiftl`/`shiftr` -- now check `idris2rc2_isUnique` on their
operand(s) and reuse a unique one's own `mpz_t` storage as the
destination in place, falling back to a fresh allocation otherwise) plus
a small compiler-side skip (`Compiler.RC2.EmitUtil`'s
`isReuseConsumingOp`, consulted by `Compiler.RC2.Emit`'s `ROp` case to
stop emitting the now-redundant post-call drops for exactly those 10
ops). `Div IntegerType` was deliberately left out of scope (a real
multi-statement algorithm, not a macro one-liner); `Double`/`Int64`/
`Bits64` reuse is a natural but not-yet-attempted follow-up.

Verified with a new regression test, `rc2/tests/Test49IntegerOpReuse.idr`
(`bigFactorial`, a self-tail-recursive accumulator past both the
small-int cache and 64-bit range, plus `bigBitOps` exercising the
bitwise/shift/mod ops via `Data.Bits`): full `verify.sh --regen-expected`
(87/87) and `refc-suite/run.sh` (19/19) both pass, `valgrind
--leak-check=full` reports `0 bytes definitely lost`, and the generated
C was hand-inspected to confirm the targeted calls emit no trailing
`idris2rc2_drop` at all while an untouched comparison primitive
(`idris2rc2_lte_Integer`, via `Prelude_Types_prim__integerToNat`) still
does. See `rc2/doc/rop-reuse.md` for the full design writeup, including
the multi-occurrence (`x + x`) and concurrency safety arguments.

## Retired: `Compiler.RC2.Emit`'s FFI wrapper treated `"RC2:"`-tagged `CFBuffer` arguments as generic-C instead of RefC-style

`emitGenericForeignWrapper`'s own `cLang` binding, which chooses
between `EmitUtil.idr`'s two `CFBuffer`-unwrap cases (`CLangRefC`,
passing the whole size-header-carrying `IDRIS2RC2_Buffer` allocation
`rc2/support/rc2/buffer.h`'s macros expect, vs `CLangC`, which skips
past that header for generic byte-buffer functions with no notion of
it), used to check only `lang == "RefC"` -- so every `"RC2:"`-tagged
declaration (rc2's own `%foreign_impl` patch mechanism, `EmitUtil.idr`'s
`ffiTags`) fell through to the `CLangC` unwrap regardless of what it
actually targeted. Silently correct for every `"RC2:"` patch written so
far (`System.Concurrency.RC2`), since none of those happen to take a
`CFBuffer`-typed argument -- only surfaced once `libs/rc2base/src/Data/
Buffer/RC2.idr` (wiring five upstream `Data.Buffer` primitives with no
RefC/C backend, see `TODO.md`) was written, the first `"RC2:"` patch to
have one.

Investigated and fixed immediately, before ever shipping: `cLang` now
checks `lang == "RefC" || lang == "RC2"`, a one-line change. Verified
with `Data.Buffer.RC2`'s own regression test (`libs/rc2base/tests/
TestBufferRC2.idr`, round-tripping negative/boundary values through all
five patched primitives) plus a full `rc2/tests/verify.sh` run
(refc-suite 19/19, smoke+valgrind 82/82) confirming no other
`"RefC:"`/`"RC2:"`-tagged call site changed behavior.

## Fixed: Compiler.RC2.Emit's tryBuildClosureInto used to double-emit a peeled wrapper's own side effect

`tryBuildClosureInto` peels leading `RDup`/`RDrop`/`RFree`/`RLet`
wrappers off a value on the way to building a closure directly into its
sink, emitting each wrapper's own side effect (a dup/drop/free call, or
a let declaration) as it goes. An earlier version returned a bare
`Bool` instead of `Maybe RCExp` -- when the search dead-ended partway
through (nothing left shaped like a closure to build), the caller had
no way to resume from what was left after the already-peeled wrappers,
and re-ran `emitRC` on the original, unpeeled value instead, re-emitting
every wrapper's own side effect a second time. Any Boxed `RLet` whose
value was e.g. an RDup-wrapped non-tail-position `RAppName` -- an
ordinary, common shape, not exotic -- had its dup emitted twice,
permanently leaking one reference. Found via `Prelude.Types.foldr`.
Fixed by returning `Maybe RCExp`: `Nothing` when the closure was built,
`Just leftover` naming exactly the innermost un-peeled expression the
caller must resume from instead of `value` itself.

## Fixed: Compiler.RC2.Emit's emitNativeValue used to drop a native-read Boxed operand before the value was actually read

`emitNativeValue` returns the native C expression for a value together
with any Boxed locals its own tail op reads but doesn't own a further
use of (`Compiler.RC2.RC`'s `annotate` already decided those are
"consumed" here). An earlier version of this fix emitted the drop for
those locals unconditionally, inside `emitNativeValue` itself, before
the returned expression string was ever embedded in the caller's own
statement -- freeing the value out from under its own extraction. A
real regression for heap-allocated 64-bit types. Fixed by handing the
drop back to the caller (either `emitRC`'s `RLet` case, or
`emitNativeValue`'s own `RLet` case) as part of the return value, so it
only ever runs *after* the statement that actually reads the
expression has been emitted.

## Fixed: a literal-constant FFI argument broke `Compiler.RC2.Emit`'s Boxed-argument-drop tracking for the FFI-inline call-site rewrite

Found while building the FFI-inline call-site splicing described in
"Retired: FFI worker synthesis (Stage 3c) no longer emits a standalone
worker C function at all" above: an earlier version of the new
`ffiArgMarshal`'s own Boxed-position drop set (what became
`ffiRawCall`'s own `boxedArgDrop`, consumed by `emitAppFFIInlineInto`/
`emitNativeValue`'s own `RAppFFIInline` case) carried raw `RCLocal`s,
rendered via the same bare `varName` every ordinary `postDrop` entry
already uses safely. That assumption -- "every dropped argument is a
named variable" -- doesn't hold for a raw FFI call argument
specifically: unlike `RAppNameRep`'s own `postDrop` (always a genuine
`RCLoc` by construction), a `%foreign` call's own Boxed-typed argument
can itself be a literal `RCConst` (e.g. a `String` literal passed with
no enclosing `let`) -- `varName`'s own `RCConst` case is a deliberately-
unreachable placeholder everywhere else in `Emit.idr` precisely because
nothing else ever hands it one. Produced an undeclared/wrong C
identifier -- a C compilation failure, not a silent runtime bug. Fixed
by carrying already-rendered C expression text for the drop set instead
of raw `RCLocal`s: `ffiArgMarshal` now returns `(String, Maybe String)`
(the argument's own render, and separately its own drop-ready render
when genuinely Boxed, via the same `rcVarToBoxedC` that already handles
constant-staging/`InlineMap` correctly), which widened
`emitNativeValue`'s own "pending drop" contract project-wide from `List
RCLocal` to `List String` (every other producer -- `RV`, `RAppNameRep`,
`ROp` -- already had a genuine `RCLocal` in hand, so this only ever
meant one extra `map varName` at each of those existing call sites, not
a behavior change for them). Re-verified against
`rc2/tests/Test27FFIDualABI.idr`'s own `prim__mixed50` (a
`String`-typed argument, deliberately included in that test for this
reason); full `verify.sh`/`refc-suite/run.sh` (19/19) unaffected.

## Fixed: `Compiler.RC2.Emit`'s new `emitAppFFIInlineInto` was missing a `(IDRIS2RC2_Value*)` cast on its own boxed FFI return

Found during the same FFI-inline call-site splicing work as the entry
above. `emitGenericForeignWrapper`'s own pre-existing boxed-return
handling already casts `packCFType`'s own result explicitly, because
`packCFType`'s "mk" functions don't all literally return
`IDRIS2RC2_Value *` (e.g. `CFStruct`/`CFPtr`'s own `idris2rc2_mkPointer`
returns `IDRIS2RC2_Pointer *`) -- the first version of the new
`emitAppFFIInlineInto` omitted this cast on its own, structurally
identical `packCFType (peelIORes ret) rawExpr` call, since it was
written fresh rather than copied from the wrapper's own code. Silent
for every purely-scalar `%foreign` declaration (their own `packCFType`
results already happen to be `IDRIS2RC2_Value *`), only surfacing as a
real `-Wincompatible-pointer-types` compile error for a `CFStruct`/
pointer-returning declaration. Caught by
`rc2/tests/Test24CStructSupport.idr`'s own `prim__makePoint : Int ->
Double -> PrimIO Point` -- both arguments native-eligible (so it gets
an FFI worker at all) but its `Point` return is `CFStruct`, called in a
genuine non-tail position (`p <- primIO (prim__makePoint 3 4.5)` inside
`main`'s own `do` block), so the call-site rewrite actually fires and
hits this code path. Fixed by adding the same explicit
`(IDRIS2RC2_Value*)` cast, matching the wrapper's own established
convention verbatim. Re-verified: `Test24CStructSupport.idr` compiles
and runs correctly again; full `verify.sh`/`refc-suite/run.sh` (19/19)
unaffected.

## Fixed: `Compiler.RC2.Emit`'s `generateCSourceFile` silently ignored a failed C-file write

Found while redesigning `generateCSourceFile` to stream generated C text
to disk per-definition instead of buffering the entire file in memory
(the two-pass structure `d41b2c8`'s own commit message noted it hadn't
addressed -- see that commit and this project's own `rc2/doc/`-adjacent
design notes for the full "why now" story: prototypes/headers/struct
typedefs are signature-only and need no body recursion, and constant
`static` definitions turned out to have no whole-program forward-
reference requirement either, needing only to precede the first
definition that references them -- so both can be produced/flushed
incrementally, def by def, with `Compiler.RC2.EmitUtil`'s existing
`ConstConDef` pending-queue field reused as the constant-staging
mechanism, rather than accumulating the whole file as one in-memory
`Output`/`DList`).

The old single-shot write path was:

```idris
coreLift_ $ withFile outn WriteTruncate pure $ \h => do
    traverse_ (fPutStrLn h) (reify fileContent)
    pure (Right ())
```

Two independent bugs here, both silent: `traverse_` runs in `IO`, so
each `fPutStrLn`'s own `Either FileError ()` result was just a discarded
value, never short-circuiting on a write failure -- and the lambda
unconditionally returned `pure (Right ())` regardless. Worse, `coreLift_`
(`= ignore (coreLift op)`) swallowed `openFile`'s own failure too. Net
effect: pointing `--cg rc2` at a read-only output directory produced no
error at all -- confirmed to silently leave a *stale* previously-written
`.c` in place, which the next stage (gcc) then happily compiled,
producing a binary from outdated generated code instead of any diagnostic
pointing at the real problem.

Fixed as part of the same redesign: `generateCSourceFile` now drives
`openFile`/`closeFile` directly (the same `coreLift` idiom
`Core.Core.writeFile` itself already uses, needed here regardless since
`Core` has no `HasIO` instance for `withFile`'s own `HasIO io`-polymorphic
continuation to run in), and every line write goes through a small
`putLines` helper that `throw`s `Core.Core.FileErr` -- an existing
`Error` constructor, no new exception type needed -- on the first
failure, `openFile`'s included. Re-verified by pointing the output
directory read-only again: now produces a clear `File error (<path>):
...` compiler error, no C compilation attempted, no stale binary
produced. Full `verify.sh` (84/84) unaffected.

## Pre-existing `valgrind` leaks (unrelated to whatever's currently being tested)

Found incidentally while re-running `valgrind --leak-check=full` across
the smoke-test matrix during `Compiler.RC2.ConAltNative`'s own
verification (2026-08-14) -- confirmed present **with that pass's own
pipeline entry removed entirely** too, so they predate and are
unrelated to that work specifically. Not investigated further yet;
small enough (a few dozen blocks) that they haven't blocked shipping
anything so far, but don't be surprised by them showing up again.

- **`Test1Basics.idr`: `definitely lost: 40 bytes in 2 blocks`,
  `indirectly lost: 56 bytes in 3 blocks`** (96 bytes / 5 blocks total).
- ~~`fastPack`/`fastConcat` leak their own raw `malloc`'d `char *` return
  on every call~~ -- **root-caused and fixed**: root-caused while adding
  `Test28Utf8Strings.idr` (the first `LEAK_SENSITIVE_TESTS` entry that
  happens to call `pack`), confirmed pre-existing and unrelated to that
  test's own UTF-8 work by reproducing the identical pattern on
  already-passing `Test5FFIStrings.idr` (`1,079 bytes in 13 blocks`,
  entirely `fastPack`/`fastConcat` frames, not previously
  valgrind-checked). Both are declared
  `%foreign "RefC:fastPack"`/`"RefC:fastConcat"` with a `CFString`
  return, so `Compiler.RC2.Emit`'s generic FFI wrapper codegen wraps
  their raw `char *` in `idris2rc2_mkString` (which `memcpy`s into a
  fresh `IDRIS2RC2_String`, per `rc2/support/rc2/memory.c`) and never
  frees the original -- correct for the common case (a real external
  library's own `char *` return, e.g. `curl_easy_strerror`, must *not*
  be freed by the caller), wrong for these two specifically, which
  `malloc` a buffer this project itself owns. A first fix
  (`libs/rc2base/src/Prelude/Fix/RC2.idr`, using upstream's own
  `%transform` mechanism to substitute in leak-free
  `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` replacements) only reached a call
  site within its own importer's elaboration scope, so it could never
  fix a call already baked into precompiled `network`/`base` package
  code -- `Test35NetworkLoopback` (via `Network.Socket.Data.parseIPv4`'s
  own `fastPack` call parsing `accept`'s `getSockAddr` result) and
  `Test37SystemMisc` (formerly `Test40SystemProcess`, via
  `System.File.ReadWrite`'s `fRead'`'s own
  `fastConcat` call reading back a spawned process's captured output)
  each kept a `KNOWN_LEAK_BYTES` entry in `verify.sh` (10 bytes / 4
  blocks, and 11 bytes / 1 block, respectively) even after that fix
  landed. **Properly fixed** by intercepting this at rc2's own
  C-emission time instead (`Compiler.RC2.Emit`'s
  `fastPackFixedReplacement` + `createCFunctions`'s `MkRCForeign` case):
  every `Prelude.Types.fastPack`/`fastConcat` call site, project-wide --
  including ones already compiled into `network`/`base`'s own `.ttc` --
  now gets redirected, at codegen time, to call the leak-free
  `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` C implementations directly, with the
  external symbol name/signature left unchanged so no call site anywhere
  needs to be recompiled. `Prelude.Fix.RC2` (the first, `%transform`-based
  fix) was retired as redundant once this landed. `verify.sh`'s
  `KNOWN_LEAK_BYTES` map is now empty; both tests confirmed 0 leaked
  bytes, and a new test, `Test46FastPackUnconditional.idr`, confirms the
  fix fires with zero opt-in imports. Full write-up, including a second,
  unrelated empty-string-write SIGSEGV bug found and fixed along the way,
  in `rc2/doc/fastpack-fix.md`.
- ~~`Test9SelfTailLoop.idr`: `definitely lost: 784 bytes in 49
  blocks`~~ -- **root-caused and fixed**: `RLoopContinue` (`Compiler.RC2.Loop`'s
  own self-tail-loop-continuation node) had no `postDrop` field at all,
  unlike every other RCExp construct that reads a `Boxed` value natively
  (`ROp`/`RCmpCase`/`RAppNameRep`), so a native-shadowed loop param fed by
  a still-Boxed, `case`-valued continuation argument (e.g. `collatzLike`'s
  own `mod`/`div` results) got read natively but never dropped. See
  `TODO.md`'s git history and `rc2/doc/loop-conversion.md` for the full
  investigation; `rc2/tests/Test16LoopContinuePostDrop.idr` is this fix's
  own dedicated regression test.

## Runtime: `RFree` rarely fires in practice (not a bug)

`RFree` (unconditional, unchecked deallocation for provably-fresh
unshared allocations) is implemented and reviews fine structurally, but
essentially never appears in generated code for ordinary Idris2 source:
Idris2's own frontend multiplicity-based dead-code elimination removes
the only kind of binding that would trigger it before `RC.idr` ever
sees it. Confirmed inherent to upstream Idris2's own pipeline, not
rc2-specific (RefC has the same non-firing behavior for the same
reason). If a `grep idris2rc2_free` across generated `.c` output comes
back empty, that's expected, not a sign the feature is broken. See
`TODO.md`'s own "Runtime: RFree rarely fires in practice" entry.

## Explicitly *not* a known bug (resolved, documented so it isn't rediscovered as one)

- **`idris2rc2_dropReuseConstructor` (`support/rc2/runtime.c`) not
  recursively dropping the released constructor's own fields was
  suspected to leak an abandoned constructor-reuse reservation's still-
  live fields.** Two rounds of investigation: the first (analysis-only)
  concluded this was reachable; actually compiling and valgrind-checking
  the proposed repro proved that conclusion wrong -- `RC.idr`'s own
  ordinary per-branch dead-variable cleanup already drops any field
  that's genuinely dead in an abandoning branch, before
  `idris2rc2_dropReuseConstructor` is ever reached, so the "missing"
  recursive drop would double-drop, not fix anything. A second round
  found the actual structural reason this is unreachable, not just
  unreachable-for-this-shape: `Compiler.RC2.Reuse`'s `resolveAlt`
  partitions every one of a destructured constructor's own fields into
  exactly two disjoint sets by plain set subtraction --
  `dupOnShared`/`dropOnUnique` (`dropOnUnique = conArgsRC \\
  dupOnShared`) -- with no third bucket a field could fall into and be
  missed. `EmitUtil.idr`'s `emitReuseOffer` fully discharges both sets
  (dup what's still needed, drop what's dead) before a reservation is
  ever claimed or abandoned, so by the time
  `idris2rc2_dropReuseConstructor` runs, every field's ownership is
  already resolved -- recursively dropping `args[]` there would drop
  already-discharged references. (`dropOnUnique` itself was added by an
  unrelated, later session's `RExtPrim`/GCPointer-adjacent fix -- this
  edge case predates that field and is fully closed by it now.) See
  `rc2/doc/reuse-analysis.md`'s own updated "Known, deliberately-
  unfixed edge case" section for the full writeup. `runtime.c`'s
  `idris2rc2_dropReuseConstructor` needs no change and should not be
  "fixed" as originally proposed.
- **`idris2-missing-containers`'s own `benchmarkHashMap` "crash"
  (`Unhandled input for Main.case block`) was never an environment or
  rc2 bug.** An earlier investigation (2026-08-14) concluded it was a
  pre-existing environment issue after it reproduced against stock
  `idris2 --cg refc` too -- that conclusion was wrong. Root cause: the
  benchmark's own `Main.idr` opens `test/input_large`/`test/words` via
  package-root-relative paths with no `Left` branch coded for
  `openFile` failure, so running the compiled binary from any directory
  other than the package root (`install/idris2-missing-containers/`)
  surfaces as exactly this crash, on every backend, regardless of
  commit -- which is also why the original bisection looked so
  consistent. Run from the correct directory, it completes correctly on
  all three backends. See `rc2/BENCHMARKS.md`'s own "訂正" note. If this
  error resurfaces, check the working directory first.
