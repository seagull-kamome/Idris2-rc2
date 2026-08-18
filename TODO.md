# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## Performance: tail-position delegating calls stay boxed

Native type inference (`Compiler.RC2.Types`) only applies to values
that stay within a single function's ANF-normalized body -- every
function argument and return value used to always be boxed, meaning
native representations got boxed and reboxed at every call boundary.
Self-tail-calls sidestep this for loops specifically (`Compiler.RC2.Loop`,
see `rc2/doc/loop-conversion.md`), and the dual calling convention
(`Compiler.RC2.DualABI`, see `rc2/doc/dual-abi.md`) closes the gap for
essentially every *non-tail-position* call boundary too. What's left, deliberately:
a **tail-position** call to a function with a native-signature worker
still goes through that function's own unchanged, fully-boxed wrapper,
permanently -- see `doc/dual-abi.md`'s own Stage 4 "Scope" section for
why (bypassing the closure-deferral/trampoline mechanism such a call
currently relies on to bound C stack growth would need real
interprocedural analysis this whole effort has otherwise avoided
needing). Believed comparatively rare in practice (a *pure* delegation
with no arithmetic of its own, e.g. `g x = h x`); revisit if profiling
ever shows otherwise.

`numeric.c`'s Boxed-value arithmetic/comparison/cast wrappers (the ones
called at every call boundary, where native inference doesn't reach)
are `static inline` in `numeric.h`, so the C compiler folds away their
own call overhead -- doesn't touch the actual (now largely closed)
boxing/reboxing gap above, just removes one small cost that used to sit
on top of it.

## Performance: loop accumulator threaded only through helper calls stays boxed

A loop-carried accumulator only skips boxing across iterations when
it's read directly as an `ROp`/`RCmpCase` operand inside the loop body
itself (`Compiler.RC2.Loop`'s own native-shadow promotion, see
`rc2/doc/loop-conversion.md`). When it's instead only ever passed *as
a call argument* to a helper function (e.g. a `step`-shaped function
called from within the loop), it stays boxed across iterations:
`nativeArgTypes` has no case recognizing "used as an argument at a
position a callee's own native-signature worker accepts natively" as
a native-context use. Unaddressed, would need its own follow-on change
(teach `nativeArgTypes` about `RAppNameRep`/`callRep` argument
positions); not currently planned. The related but distinct gap for an
ordinary case-alternative's own destructured field (not loop-carried)
was addressed separately (`Compiler.RC2.ConAltNative`, see
`rc2/doc/con-alt-native.md`).

## Dropped: loop-invariant constructor-field hoisting

Two entries, investigated and dropped together -- "loop-invariant
single-branch case hoisting" and `ConAltNative`'s once-planned
extension "across loop/dual-ABI boundaries" turned out to be the same
underlying gap wearing two different names. See
`rc2/doc/case-hoisting-scope.md` for the full writeup (why it looked
worth doing, what the investigation found, and why neither design
considered was pursued).

## Performance: constructor reuse doesn't reach across a monadic-bind continuation

Investigated why `Compiler.RC2.Reuse` doesn't fire on
`idris2-missing-containers`' `benchmarkHashMap` hot path (a bucket-list
`replaceL2` that destructures and reconstructs a same-shape `::` cell)
despite it being a textbook reuse candidate. Root cause confirmed via
`--directive dumprcexp`: the reconstruction happens inside a separately
lambda-lifted definition reached only through a genuine partial
application (a monadic-bind continuation, from `HasIO io =>`-polymorphic
`!`-bang-notation code -- not from `with` specifically, a case-based
rewrite of the same shape has the identical gap). `Reuse`'s own
eligibility check is intentionally, purely intraprocedural (any call is
a dead end); a proposed fix (inline single-call-site, fully-saturated-call
definitions before `Reuse` runs) is sound in principle but doesn't reach
this specific case, since the call in question is a genuine partial
application, not a fully-saturated one. Not pursued further -- full
investigation, both refuted hypotheses, and what a real fix would need
are in **`rc2/doc/reuse-monadic-bind-gap.md`**.

## Scope: deliberately unboxed types stop at scalars

`Integer` (GMP arbitrary precision) and `String` are never candidates
for native-representation inference -- only fixed-width numeric types
(`Int`, `Bits8`/`16`/`32`/`64`, `Int8`/`16`/`32`/`64`, `Double`, `Char`).
This is a deliberate scope boundary, not a bug, but revisiting it (e.g.
a native "small string" representation) is plausible future work if
profiling ever shows it matters. Comparison/branch fusion (`RCmpCase`,
see `Compiler.RC2.RC`'s `tryFuseCompare`) follows the same boundary --
`LT`/`GT`/`EQ`/`LTE`/`GTE` over `Integer` or `String` still always
materialize a boxed `Bool`, even when immediately consumed by a branch;
only comparisons over the fixed-width/`Double`/`Char` types above skip
that materialization.

## Architecture: one optimization decision still lives in Emit.idr

`Emit.idr`'s own module note claims it's purely mechanical -- every
ownership/native-vs-boxed decision already made by `Compiler.RC2.RC`
and lowered as-is. One spot (value-based, not shape-based, which is
why it wasn't folded into the same elevation as `ROp.postDrop`/
constructor-reuse/single-use closure-building) doesn't actually fit
that description yet:

- **Small-int cache / constant-staging threshold** (`RPrimVal`'s
  `dyngen`/`orStagen` in `Emit.idr`): decides, based on a literal's
  *value* (`[0,100)` for the small-int cache; `ConstDef`/`SortedMap`
  keyed staging to deduplicate repeated same-value boxed constants)
  which representation strategy to use, entirely at emission time.
  Elevating it would mean `RC.idr`'s Phase 1 either duplicating
  knowledge of the small-int cache range, or `Emit.idr` keeping a
  genuinely emission-scoped concern anyway (constant deduplication
  naturally wants a single table spanning the *whole compiled file*,
  not per-definition, so it doesn't fit the "decide once per node
  during Lifted -> RCExp conversion" pattern the other elevations use).
  Not obviously wrong to leave as-is; flagged for a decision, not a
  known bug.

## Concurrency: unchanged from RefC

Reference counting stays non-atomic, matching RefC's own single-threaded
assumption. If rc2 ever needs to support genuinely concurrent mutation
of shared values, this needs revisiting (atomic refcounts at minimum,
possibly a different GC strategy). Not addressed, not currently planned.

## Test coverage gaps

Two of upstream Idris2's own `tests/refc/*` regression tests were
deliberately not ported (see `rc2/tests/refc-suite/README.md` for the
full reasoning):

- **`ccompilerArgs`**: verifies that `CFLAGS`/`LDFLAGS`/`LDLIBS` env vars
  reach the C compiler invocation. `Compiler/RC2/CC.idr` has equivalent
  flag-handling logic, but it's currently *unverified by a test* --
  porting upstream's test faithfully (its own companion C library,
  env var wiring) was judged out of proportion to do alongside the rest
  of the regression-suite port. Worth doing as a focused follow-up.
- **`callingConvention`**: upstream's version `awk`-inspects the shape
  of RefC's own generated C, which isn't meaningful for rc2's
  structurally different codegen. No rc2-specific replacement exists
  yet that would pin down the *current* calling convention's C shape
  (now partly dual-ABI'd for eligible functions, see
  `rc2/doc/dual-abi.md`) as a regression guard -- worth writing from
  scratch.

## Runtime: RFree rarely fires in practice

`RFree` (unconditional, unchecked deallocation for provably-fresh
unshared allocations) is implemented and type-checks/reviews fine
structurally, but was observed to essentially never appear in generated
code for ordinary Idris2 source: Idris2's own frontend multiplicity-based
dead-code elimination removes the only kind of binding
(`dropDeadLet`'s target: a let-bound value that's never used) that would
trigger it, before `RC.idr` ever sees it. Confirmed this is inherent to
upstream Idris2's pipeline, not rc2-specific (RefC has the same
non-firing behavior for the same reason). Not a bug to fix, but noted
here in case a future frontend change or a different lowering strategy
changes when `RFree` becomes reachable, so its rarely-exercised code path
gets renewed scrutiny then.

## Correctness: `--directive noreuse` corrupts the heap on several smoke tests

`rc2/tests/verify.sh --directive noreuse` (see its own "--directive"
option, added to let a session compare an optimisation pass on vs.
off) surfaces a real heap corruption in 11 of 17 smoke tests
(`Test1Basics`, `Test2Recursion`, `Test3Data`, `Test4Closures`,
`Test5FFIStrings`, `Test7CastMatrix`, `Test8EmptyCon`,
`Test9SelfTailLoop`, `Test10MutualLoop`, `Test12ConAltNative`,
`Test13NativeArgChain`) -- `malloc(): unaligned tcache chunk detected`
at runtime, not a compile error. `--directive noconaltnative` alone is
unaffected (all 17 pass); the corruption is specific to disabling
`Compiler.RC2.Reuse` itself, not something `ConAltNative` depends on.

Not investigated further yet -- likely a later pass
(`ConAltNative`/`MutualLoop`/`Loop`/`DualABI`, or `Emit` itself)
implicitly relies on `Compiler.RC2.Reuse` having already run (e.g.
assuming every `RCon`'s own `reuseFrom` field, or the absence of a
dangling `RReuseOffer`/`RReleaseReuse`, in a way that's silently wrong
when `Reuse` is skipped) rather than being a genuinely independent,
disableable stage the way `--directive noconaltnative`/`noloop`/etc.
are. Doesn't affect the default pipeline (`Reuse` always runs unless
explicitly disabled), so it's not a correctness bug in what ships --
only surfaces via this debug flag -- but worth root-causing before
trusting `--directive noreuse` for any future performance comparison.

Repro: `cd rc2/tests && ./verify.sh --skip-build --no-valgrind --directive noreuse`.

## yet another hope
この項は人間が追加したものなので、後で整理して独立の項に括りだす事。
今は着手しないが将来的な展望を書き連ねる。この項は日本語で書かれるが
翻訳する必要はない。計画立案して項を独立した時に英語になっていればよい。

- Cのレベルで無駄な代入が相変わらず発生している。Cコードの可読性を向上させたい
- カスタムメモリアロケータに対応したい。例えばpythonに組み込む時にpython側
  のアロケータを使えれば効率化につながるのでは？
- slabの様にfree-list風に高速割り当てできる固定アロケータを使えるようにしたい。
- マルチスレッド対応は別にネイティブスレッドを使える必要はないはず。
  ランタイム提供するワーカースレッドを使ったdotnetのTask風機能は比較的簡単に
  作れるのでは？
- 変数がタグ付きポインタ化された32ビット未満整数の場合、ネイティブ化されていなくても
  dup/dropを省略できる。
- 比較演算子の融合はinline展開の後にやらないと効果が限定されてしまうのでは？
- libgc板のランタイム。dup/drop/freeをCマクロで消去してしまい、mallocを単純に差し替える
  だけでlibgc対応できるのでは？
- 短い文字列をタグ付きポインタに押し込む
- 定数のCast畳み込み、Char/Double絡みとString→数値方向は未対応（理由はrc2/doc/cast-fold-scope.md参照）






