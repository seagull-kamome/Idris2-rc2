# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## Architecture: `RCLocal` can't hold another `RCLocal`

While designing `getField`/`setField` support (`rc2/doc/c-struct-support.md`),
considered making a struct field read a new `RCLocal` variant (e.g.
`RCStructField : RCLocal -> String -> String -> RCLocal`) instead of a
dedicated `RCExp` node -- it's a pure, ownership-neutral read, so it
would have been usable directly as an `ROp`/`RCon`/etc. operand, no
`RLet` needed just to name it first. Not pursued: `RCLocal`
(`RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`) is currently *atomic* --
every existing user (`freeLocalsR`/`countUsesR` in `RCExp.idr`,
`splitBorrows`/`boxedOperands` in `RC.idr`, and similar code across
`Reuse.idr`/`Sink.idr`/`Loop.idr`/`DualABI.idr`) relies on plain `==`
comparison and `fromList`/`filter` over `List RCLocal`, which only
works because no variant currently holds a nested `RCLocal` of its
own. Adding one that does (`RCStructField`'s own `structVar`) would
mean every one of those sites needs to recurse into the nested
`RCLocal` instead of just comparing values directly -- a broader,
riskier change than adding a new `RCExp` node (which only affects
`RCExp`-walking code, a smaller and more precedented surface, see
`Compiler.RC2.RC`'s own `ROp`-shaped precedent for `RStructGet`/
`RStructSet`). Went with the `RCExp` node instead. Worth reconsidering
if a future feature would benefit from embeddable-value locals badly
enough to justify auditing every `RCLocal` call site -- not currently
planned.

## Performance: native (unboxed) `Ptr`/`CFPtr` representation -- investigated, not pursued

Neither `getField`'s own result nor `setField`'s own `value`, nor a
struct pointer (`structVar`) itself, is ever native -- each pays for a
Boxed `IDRIS2RC2_Pointer` heap allocation just to carry one raw
pointer around. Investigated whether `Ptr`/`CFPtr` could join rc2's
existing native-representation machinery. Structurally blocked before
the semantics even come up: `Rep`'s `RNative`/`RInlineNative` are typed
over upstream's own `PrimType`, which has no pointer case at all, so
representing one at all needs a new `Rep` variant of rc2's own,
touching every module that pattern-matches on `Rep`. Semantically
murkier too: `CFGCPtr`'s own `onCollect` callback genuinely depends on
refcounting to fire, so it would need permanent exclusion (`CFPtr`
only); and even `CFPtr` alone would lose the weak reachability
tracking its current Boxed wrapper provides, with no borrow/lifetime
checker to make up for it once a future nested-struct-field-pointer
feature makes that tracking matter more. See
`rc2/doc/c-struct-support.md`'s own "Investigated: native (unboxed)
`Ptr`/`CFPtr` representation" section for the full writeup. Not
currently planned -- revisit only if profiling shows the allocation
cost actually matters, with a concrete plan for the `CFGCPtr` split
and the lifetime question.

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

## Performance: reboxing a native-shadowed value always allocates fresh, never reuses the original Boxed object

`Emit.idr`'s `rcVarToBoxedC` (its own doc comment states this
explicitly) boxes a `Native`/`RInlineNative` local by always calling
`nativeMk` (`idris2rc2_mkInt64`/etc.) -- a fresh allocation, never a
`dup` of whatever Boxed object the value was originally unboxed from.
This is deliberate, not an oversight: both `Compiler.RC2.Loop`'s own
native-shadow-loop-param promotion and `Compiler.RC2.ConAltNative`'s
own destructured-field caching use `renameRCExp` to redirect *every*
occurrence of the original id (native-context reads and Boxed-context
reads alike) to the fresh shadow id, then `stripOwnership` deletes the
original's own now-stale ownership bookkeeping outright -- so by the
time a Boxed-context read is reached, there's no reference to the
original Boxed object left in the tree to `dup`, only the raw scalar.
See `rc2/doc/loop-conversion.md`'s own "Native-shadow promotion"
section (step 2) for where this trade-off was first accepted ("a real
but acceptable trade-off, not a correctness issue").

Two related points worth recording alongside this:

- **The promotion decision itself doesn't weigh this cost.**
  `Loop.idr`'s `nativeArgTypes`/`nativeArgType` (the eligibility check
  both passes above share) only asks whether a parameter/field is ever
  read in a native context at a consistent type -- it never counts how
  many *Boxed*-context reads would each pay a fresh-allocation cost as
  a result of promoting. A variable read natively once but read Boxed
  many times could plausibly get *slower* under promotion, not faster.
  `idris2rc2_mkInt64`/`mkBits64` do have a 0-99 small-value cache
  (`memory.c`), so the real cost only bites for out-of-range integers
  and for types with no such cache (`Double`, wider `Int`/`Bits` values
  outside 0-99) -- unmeasured how often that actually happens in
  practice.
- **A more ambitious fix (not attempted, non-trivial)**: instead of
  `renameRCExp`'s blanket redirect, only redirect the *native-context*
  occurrences to the shadow id and leave every Boxed-context occurrence
  on the *original* id, letting `annotate`'s own original dup/drop
  bookkeeping for that id keep working unmodified (a native-context
  read never needs a `dup` regardless, so removing just the
  dup/drop entries tied to the redirected occurrences -- not all of
  them, unlike today's `stripOwnership` -- should be sound in
  principle). Would touch `renameRCExp`/`stripOwnership`'s own
  all-or-nothing shape in both `Loop.idr` and `ConAltNative.idr`; not
  designed further than this. Neither this nor the cheaper
  eligibility-side fix above has been attempted -- not currently
  planned, revisit if profiling shows reboxing cost actually matters.

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
- **Performance: Closure Inlining and Immediate Expansion**
  `partial`呼び出しによるクロージャ生成とヒープ割り当てが、高階関数や型クラスの辞書使用時に頻発している。特に`List`操作や`mapAppend`のような高階関数において、`Boxed`なクロージャが多重生成されており、パフォーマンスを大きく阻害している。
  - 可能な限りコンパイル時にクロージャを特定し、直接呼び出しへとインライン展開するパスを実装する。
  - スコープ内で閉じている静的な定数クロージャは、最適化パスで完全にインライン化・削除を行う。

- **Performance: Static Data Embedding**
  定数データ（リストやCONSセルの連鎖など）が、実行時に毎回ヒープ上で動的割り当て（`_builtin.CONS`等）されている。
  - コンパイル時に値が完全に確定しているデータ構造は、実行時の動的割り当てを排除し、バイナリの静的データ領域（`.rodata`）に配置することで、初期化コストとメモリ割り当てコストをゼロにする。

- **Performance: Higher-Order Function Specialization**
  `mapAppend`のような汎用的な高階関数は、すべて`Boxed`な値を引数に取るため、頻繁なポインタ参照とヒープ割り当てが発生している。
  - 特定の型（例：`List Double`）に対して高階関数が呼び出されている場合、コンパイル時に型特化した関数を生成する（テンプレート化/マングリング）。
  - 特化により、`Boxed`なCONSセル走査を、ネイティブな配列走査へと置き換え、参照カウント操作を削減する。






