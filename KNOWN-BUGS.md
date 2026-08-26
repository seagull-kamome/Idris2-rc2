# Known bugs and quirks (not going to surprise you again)

Confirmed, already-investigated issues that show up while testing rc2
but are **not** rc2 regressions to chase down again -- either a defect
in a *reference* installation (nixpkgs' RefC support library), an
already-understood quirk of the test file itself, or a pre-existing gap
confirmed unrelated to whatever work is in progress when it's
rediscovered. Kept separate from `TODO.md` (forward-looking gaps/future
work) and `rc2/tests/refc-suite/README.md` (bugs found *and fixed*
during that port) specifically so re-running the test suite doesn't
trigger a fresh investigation of something already closed out.

If one of these stops reproducing, or a fix lands, update or remove the
entry rather than leaving it stale.

## Real reference-installation bugs (not rc2 bugs)

- **`Test7CastMatrix.idr` can't be diff-checked against real
  `idris2 --cg refc` at all.** The nixpkgs-bundled RefC support library
  itself fails to compile: `idris2_negate_Double` is typo'd as
  `idris2_nagate_Double` in its own headers, plus a couple of missing
  declarations. Confirmed to be a defect in that reference installation
  itself, not rc2 -- `idris2-rc2`'s own build of the same file compiles
  and runs cleanly. Verified instead via a saved `.expected` file
  (manual verification), same as `rc2/tests/refc-suite`'s own
  `Test7CastMatrix`-equivalent handling. See `rc2/doc/dual-abi.md`'s own
  "Verification methodology" item 5 / `rc2/doc/reuse-analysis.md`'s
  item 4 for the original write-up.
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
  no real-RefC output to diff against in the first place.

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
- **`fastPack`/`fastConcat` leak their own raw `malloc`'d `char *` return
  on every call** -- root-caused while adding `Test28Utf8Strings.idr`
  (the first `LEAK_SENSITIVE_TESTS` entry that happens to call `pack`),
  confirmed pre-existing and unrelated to that test's own UTF-8 work by
  reproducing the identical pattern on already-passing `Test5FFIStrings.idr`
  (`1,079 bytes in 13 blocks`, entirely `fastPack`/`fastConcat` frames,
  not previously valgrind-checked). Both are declared
  `%foreign "RefC:fastPack"`/`"RefC:fastConcat"` with a `CFString`
  return, so `Compiler.RC2.Emit`'s generic FFI wrapper codegen wraps
  their raw `char *` in `idris2rc2_mkString` (which `memcpy`s into a
  fresh `IDRIS2RC2_String`, per `rc2/support/rc2/memory.c`) and never
  frees the original -- correct for the common case (a real external
  library's own `char *` return, e.g. `curl_easy_strerror`, must *not*
  be freed by the caller), wrong for these two specifically, which
  `malloc` a buffer this project itself owns. Fixing it properly means
  teaching the wrapper codegen to free after copy for exactly these two
  (or having them build the `IDRIS2RC2_String` directly instead of
  returning a raw `char *` for the generic wrapper to copy) -- not
  attempted, out of scope for the UTF-8 work that found it.
  `Test28Utf8Strings`'s own `KNOWN_LEAK_BYTES` entry in `verify.sh`
  (28 bytes / 3 blocks, three `pack` calls) is this same bug, not a
  regression in its own String-primitive rewrite. `Test35NetworkLoopback`'s
  own `KNOWN_LEAK_BYTES` entry (10 bytes / 4 blocks) is this same bug
  again, reached via `Network.Socket.Data.parseIPv4`'s own `fastPack`
  call while parsing the peer address `accept`'s `getSockAddr` returns --
  not a networking-specific leak. `Test40SystemProcess`'s own
  `KNOWN_LEAK_BYTES` entry (11 bytes / 1 block) is this same bug yet
  again, reached via `System.File.ReadWrite`'s `fRead`'s own `fastConcat`
  call while `run`/`runProcessingOutput` read back a spawned process's
  captured output -- not a process-spawning-specific leak either.
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
- **`List.(++)` (`Prelude.Types`'s `reverseOnto`/`tailRecAppend`) leaks
  memory via `idris2rc2_newConstructor` on repeated `IORef` append.**
  Found incidentally (2026-08-25) while testing `Channel`'s
  `channelPut` for the Concurrency work (`rc2/doc/concurrency.md`,
  commit `05c5c78`), but confirmed unrelated to concurrency: reproduces
  on a plain, single-threaded program that
  `modifyIORef`/`writeIORef`-appends to a `List` a handful of times
  (three appends was enough in `libs/rc2base/tests/
  TestConcurrency.idr`'s own test), no `fork`/`Mutex`/thread involved
  at all -- `channelPut`'s test just happened to be the first thing in
  this codebase to exercise `List.(++)` this way. On the order of
  40-280 bytes per run in this test's own `valgrind` numbers. Not
  root-caused or fixed, only found and reproduced; see `TODO.md`'s own
  matching entry.

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

## Runtime: constructor-reuse reservation abandonment doesn't recursively drop fields (latent, unverified, not fixed)

`idris2rc2_dropReuseConstructor` (`support/rc2/runtime.c`) does *not*
recursively drop the released constructor's own fields, unlike an
ordinary `idris2rc2_drop`'s teardown. Confirmed pre-existing (predates
`Compiler.RC2.Reuse` moving the reuse *decision* to IR level) by
reading the runtime implementation directly. Means: if a reservation is
claimed (`isUnique` succeeded) but then never actually consumed by any
`RCon` on the specific execution path taken, that path's own fields
aren't cleaned up by the release call itself. Not verified to be
reachable in practice (no known failing test), deliberately left
unfixed as out of scope for the work that found it. See
`rc2/doc/reuse-analysis.md`'s own "Known, deliberately-unfixed edge
case" section. If a leak ever traces back here, this is the first
suspect.

## Explicitly *not* a known bug (resolved, documented so it isn't rediscovered as one)

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
