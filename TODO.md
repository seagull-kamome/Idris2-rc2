# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

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


## Semantics: `Lazy`/`Force` defers evaluation but doesn't memoize (except one Chez-only special case)

Confirmed by direct experiment (a `Lazy Int` built via `delay
(unsafePerformIO (do putStrLn "computing!"; pure 42))`, forced twice
through a shared function parameter) that rc2's `Lazy`/`delay`/`force`
provides deferred-evaluation *timing* only, not call-by-need *sharing*:
forcing the same delayed value twice re-runs the underlying computation
from scratch both times (`computing!` printed twice), rather than
computing once and reusing the cached result the way Haskell's lazy
thunks do. The deferred-timing half still works correctly (a separate
experiment confirms the sequenced side effect inside `delay` doesn't
run until the first `force`, not at the `delay` call site itself).

Root cause, traced to `idris2-src/src/Compiler/LambdaLift.idr`: both
`rc2/src/Compiler/RC2/RC2.idr` and upstream `Compiler.RefC.RefC` call
`getCompileData` with `doLazyAnnots = False` (`RC2.idr`'s own call site,
`RefC.idr:1005`) -- **not rc2-specific**, the identical choice upstream
RefC itself makes. Under that flag, `LambdaLift.idr`'s `liftExp`
compiles `Delay e` to a plain zero-argument closure (`CLam (MN "act" 0)
e`) and `Force t` to a plain call on it (`CApp t [CErased]`) -- no
memo cell, no "already forced?" check, nothing beyond an ordinary
closure and an ordinary application. Confirmed directly in rc2's own
generated C too: a `force`d-twice value compiles to two independent
`idris2rc2_applyClosure(var_0, NULL)` calls with nothing cached between
them.

**Not actually a Chez-vs-RefC gap in general**, despite first looking
like one: a naive `idris2 --cg chez` run of the same experiment prints
`computing!` only *once*, but that turned out to be a narrow special
case, not `Force`/`Delay` sharing in general -- confirmed by re-running
the same experiment with the `Lazy` value built from a runtime
parameter instead of a closed literal (so it can't be floated to a
top-level binding), which prints `computing!` *twice* under `idris2
--cg chez` too, identical to rc2/RefC. The one-time-only result only
happens for a top-level definition (or a `let`-binding the compiler
floats to one, which happens whenever nothing in it depends on a
function argument) whose entire body is literally `Delay e`:
`Compiler.Scheme.Common.idr`'s `schDef` has a dedicated case for
exactly that shape (`MkNmFun [] (NmDelay _ _ exp)`, its own comment:
"Special version for memoized toplevel lazy definitions"), emitting
Scheme's own native `(define name (delay expr))` instead of going
through the generic `LazyExprProc`-driven `(lambda () expr)`/`(expr)`
pair every other `Delay`/`Force` site uses (`defaultLaziness`, same
file) -- and that native `delay` only ends up evaluated once *because*
Chez's own top-level `define`s are genuinely shared CAFs, unlike rc2/
RefC's (a top-level 0-argument definition is a plain function re-run on
every reference on this backend, no memoization at all -- confirmed
separately in this project's own investigation of `System.Random.
Xoroshiro128PlusPlus`'s global-state design). So the real picture: a
`Lazy` value that's a closed top-level constant is memoized on Chez
(CAF-sharing + the native-`delay` special case working together) but
never on rc2/RefC (no CAF-sharing at all); a `Lazy` value built at
runtime from live data -- the ordinary/common case, e.g. a `Lazy`-typed
function argument -- is *not* memoized on **any** of the three checked
here (Chez included).

Also investigated in passing: `LambdaLift.idr`'s other branch,
`doLazyAnnots = True`, is not a path to memoization either. Under it,
`Delay e`/`Force t` are erased entirely rather than becoming a closure
-- `e`/`t` gets lifted in place, evaluated exactly where it's written,
with only a `lazy : Maybe LazyReason` marker left on whatever call/op
node it lifts to (`Compiler.RC2.RCExp`'s own `lazy` fields on
`RAppName`/`RApp`/`ROp`/`RExtPrim` exist for this, currently always
`Nothing` since rc2 never sets `doLazyAnnots = True`). Flipping it
would *remove* rc2's current (working) deferred-timing guarantee
entirely -- `Delay`'s side effect would fire immediately, not at first
`Force` -- and buys no memoization on its own; the `lazy` marker itself
drives no runtime behavior anywhere in `Compiler.RC2.Emit` today, and
would need real new codegen (something like a C-side version of Chez's
own memoizing-thunk helper, `blodwen-lazy` in
`idris2-src/support/chez/support.ss`: a heap-allocated closure plus an
"already forced?" flag and a cached result slot) to turn that marker
into anything. No backend currently ships with `doLazyAnnots = True`
(checked Chez/Racket/Gambit/RefC/the VM interpreter -- all pass
`False`); it reads as unused groundwork for some future ANF/VM-style
backend, not a switch rc2 could usefully flip today.

Not a bug to fix -- this is RefC-family behavior rc2 deliberately
inherits unchanged, and every use of `Lazy`/`force` in this codebase's
own source (this survey's own search) happens to be single-use, so it
hasn't caused an observed problem. Noted here because it's a real,
easy-to-miss semantic gap from Haskell-style (and, for the narrow
top-level-constant case, Chez-style) lazy evaluation: code written
assuming a `Lazy` value (particularly a `Lazy`-typed function argument,
forced more than once inside the function) is evaluated at most once
will silently get O(n) re-execution instead on rc2 (and on real `idris2
--cg refc`) -- functionally correct for a referentially transparent
computation, but wrong for anything relying on the *once-only*
guarantee (a genuine side effect, or the performance assumption that
memoizing an expensive pure computation behind `Lazy` actually
memoizes it here). Revisit only if a concrete program actually needs
shared-thunk semantics badly enough to justify a real memoizing-thunk
implementation (a mutable "forced?" cell wrapping the closure, roughly
the same shape `IDRIS2RC2_IORef` already uses) -- non-trivial given it
would need to interact correctly with this project's own reference-
counting/reuse machinery, and no concrete need has surfaced yet.

**Follow-up investigated, not implemented**: could the narrow, common
"top-level constant defined as exactly `delay expr`" case (the one
Chez memoizes via its own special case, see above) be given the same
treatment on rc2, using the `lazy : Maybe LazyReason` markers
`doLazyAnnots = True` would populate? Worth checking since it looked,
at first, like a small, targeted win rather than a general memoizing-
thunk implementation. Four things came out of chasing it:

1. **Flipping `doLazyAnnots` globally is not safe.**
   `Prelude.Basics`'s `(&&)`/`(||)` are implemented over `Lazy Bool`
   for short-circuiting (`(&&) True x = x; (&&) False x = False`), and
   general corecursive structures (`Stream`, `Colist`, ...) depend on
   `Delay` never running early. Turning `doLazyAnnots` on for the whole
   program erases *every* `Delay` into immediate evaluation (this
   entry's own "Semantics" discussion above), which would break both
   outright. Any safe version of this idea has to detect and special-
   case only the exact `MkNmFun [] (NmDelay _ _ exp)` shape -- matching
   `Compiler.Scheme.Common.idr`'s own `schDef` case for it -- while
   leaving `doLazyAnnots = False` (and hence every other `Delay`/`Force`
   site's existing, correct, deferred-but-non-memoizing closure
   compilation) untouched.

2. **That detection is free, as it turns out.** Traced
   `idris2-src/src/Compiler/Common.idr`'s `getCompileDataWith`: the
   `namedDefs <- traverse getNamedDef cseDefs` line runs unconditionally,
   regardless of the requested `UsePhase` -- so rc2's own existing single
   `getCompileData False Lifted tm` call already produces a fully
   populated `cdata.namedDefs : List (Name, FC, NamedDef)`, with the
   exact `NamedDef`/`NamedCExp` shape (`MkNmFun [] (NmDelay _ _ exp)`)
   Chez's own `schDef` pattern-matches on. No second compilation pass
   needed to build the "these top-level names are pure `delay expr`
   constants" set.

3. **But changing just the 0-argument CAF's own codegen turns out not to
   be enough.** Under `doLazyAnnots = False`, `Delay e` compiles to a
   closure (`CLam (MN "act" 0) (weaken e)`), so a CAF like `sideEffect :
   Lazy Int; sideEffect = delay e` compiles to a genuine 0-argument C
   function that *builds and returns a closure object*
   (`Main_sideEffect(void) { return
   idris2rc2_mkClosure(Main_sideEffect_1, ...); }` -- confirmed against
   real generated C, not assumed; also confirmed rc2's own pipeline
   never pads a 0-argument top-level definition with a dummy parameter
   for any reason -- the only "dummy argument" concept anywhere in
   `Compiler.RC2` is `DualABI.idr`'s `CFWorld` token, which belongs to
   `IO a`'s own FFI representation, unrelated to a plain `Lazy a` CAF).
   `Force t`'s own compiled form is unconditionally `CApp fc tm
   [CErased fc]` -- "apply whatever `tm` evaluates to as a closure" --
   so memoizing only `Main_sideEffect` itself (making it return the
   *same* closure object every call, fixable with an atomic
   compare-and-swap-guarded static cache) is not sufficient on its own:
   the closure *object itself* (its body function, e.g.
   `Main_sideEffect_1`, the thing `idris2rc2_applyClosure` actually
   invokes) still has no "already forced, here's the cached result"
   state, so a second `force` on the same (now correctly shared) closure
   would still recompute. A real fix needs *both* the CAF-sharing half
   above *and* a new memoizing closure representation (a "forced?" flag
   plus a cached-value slot, checked by `idris2rc2_applyClosure` or
   equivalent) -- touching `datatypes.h`'s own closure layout, not just
   `Compiler.RC2.Emit`'s codegen for 0-argument top-level definitions.
   Meaningfully bigger than the initially-hoped-for "just change how a
   0-arg CAF compiles."

4. Were this pursued, the natural choice for guarding the memoizing
   closure's first-computation race (rc2 has real OS threads,
   `doc/concurrency.md`) is an atomic compare-and-swap/double-checked
   pattern rather than a `Mutex` -- lock-free, and acceptable since the
   worst case under a genuine race is redundant (not incorrect)
   recomputation for a referentially transparent value, the same
   tradeoff this whole entry already accepts for the *unmemoized*
   general case.

5. Point 3's conclusion (a new representation is unavoidable) isn't
   speculation -- upstream itself already ships exactly this tradeoff
   for the *general* (non-CAF) case, opt-in only, on the Scheme
   backends: `--directive lazy=weakMemo` / `%cg chez lazy=weakMemo`
   (`Compiler.Common.getWeakMemoLazy`, read only by
   `Compiler.Scheme.{Chez,Racket,Gambit}`, never by RefC or rc2) swaps
   every generic `Delay`/`Force` site from the default `(lambda ()
   expr)` / `(expr)` pair (`Compiler.Scheme.Common.defaultLaziness` --
   the same non-memoizing shape rc2/RefC always use) to
   `weakMemoLaziness`: `(blodwen-delay-lazy (lambda () expr))` /
   `(blodwen-force-lazy expr)`. Confirmed by compiling a `Lazy` value
   built from runtime data (can't be floated to a CAF) with and without
   the directive: `computing!` prints twice by default, once with
   `lazy=weakMemo` on. `idris2-src/support/chez/support.ss`'s own
   implementation:
   ```scheme
   (define (blodwen-delay-lazy f) (weak-cons #!bwp f))
   (define (blodwen-force-lazy e)
     (let ((exval (car e)))
       (if (bwp-object? exval)
           (let ((val ((cdr e)))) (set-car! e val) val)
           exval)))
   ```
   -- a genuinely new representation (a `weak-cons` pair: `car` starts
   as the not-yet-computed sentinel `#!bwp` and is overwritten with the
   result on first force, `cdr` holds the thunk), not a flag on the
   existing closure shape. And it's deliberately *weak*: `car`'s cached
   result can be GC'd if nothing else references it, silently forcing a
   recomputation on the next `force` -- "memoized as long as memory
   pressure allows", not the strict once-only guarantee the top-level-
   CAF special case's real `(delay ...)` gives via strong references.
   Confirms this dial exists precisely because unconditional *strong*
   memoization for every `Delay`/`Force` has a real memory cost upstream
   itself isn't willing to pay by default (matters for long corecursive
   chains, `Stream`/`Colist`, where pinning every historical thunk's
   result forever would defeat the point of streaming in the first
   place) -- a consideration any real rc2 implementation of point 3
   would inherit too.

Not implemented -- point 3 changes this from a small, contained fix
into a new runtime representation plus matching `Compiler.RC2.Emit`/
`idris2rc2_applyClosure` work, and no concrete program has needed it
yet. Revisit starting from this writeup (particularly points 3 and 5)
if one does.

The *plain* (non-`Lazy`) 0-argument CAF case -- a bare top-level value
built through `unsafePerformIO`, no `Lazy`/`Force` involved at all --
used to have the exact same bug (a real-world hit, `Network.HTTP.Server`'s
own `counter : IORef Int; counter = unsafePerformIO (newIORef 0)`
pattern) but is now fixed; see `rc2/doc/caf-memoization.md`'s own
"Scope" section for exactly where the boundary between "fixed" and
"still open here" (`Lazy`/`Force` itself) falls.

## Upstream stdlib `%foreign` declarations with no C/RefC backend at all

Surveyed every `%foreign` declaration in `idris2-src/libs` (206 across
27 files, `base`/`prelude`/`contrib`/`network`) for ones carrying no
`"C:..."`/`"RefC:..."` alternative whatsoever. Anything without a
C-tagged alternative is a function the *pinned reference*
`idris2 --cg refc` itself cannot call at all -- not an rc2-specific
gap. Four such spots found, all upstream:

- **`Data.Buffer`**: `setInt8`/`getInt8`/`getInt16`/`setInt64`/
  `getInt64` -- patched, see `libs/rc2base/README.md`'s
  "`Data.Buffer.RC2`" section.
- **`Data.Double`**: `unitRoundoff`/`epsilon`/`nan`/`inf` -- patched,
  see `libs/rc2base/README.md`'s "`Data.Double.RC2`" section.
- **`System.Random`** (contrib): `prim__randomBits32`/
  `prim__randomDouble`/`prim__srand` (backing the whole module) remain
  entirely unimplemented on any C backend. Not a `%foreign_impl` patch
  onto them (unlike `Data.Buffer`/`Data.Double` above) -- see
  `libs/rc2base/README.md`'s "`System.Random.Xoroshiro128PlusPlus` /
  `System.Random.Xoroshiro64StarStar`" section for two independent,
  from-scratch replacement modules with their own API instead.
- **`System.Future`** (contrib): `prim__makeFuture`/
  `prim__awaitFuture` carry only a `"scheme:..."` tag -- entire module
  unusable on any C backend, refc included, and genuinely
  un-investigated: hasn't surfaced as a real blocker for any program
  built against rc2 so far. Revisit with a `%foreign_impl` patch or a
  from-scratch replacement, `libs/rc2base`-style, if a concrete program
  needs it. Not to be confused with rc2's own, unrelated joinable fork
  (`forkJoin`/`join`/`JoinHandle`, `rc2/doc/concurrency.md`'s "Design:
  joinable fork").

One more single-function case surfaced by the same survey,
`prim__threadWait` (`libs/prelude/Prelude/IO.idr`) -- not a fresh
finding, it's the same gap `rc2/doc/concurrency.md`'s "Design: joinable
fork" section already documents at length -- included here only so
this survey is a complete index.

## Performance: codepoint-indexed String access is O(n) per call, not O(1)
CStringを他バックエンドと揃える為にutf8バイト列にした為、indexの計算コスト
が酷く劣化。
Data.TextBufferを用意すると共に、長らく動いていなかった文字列イテレータを
整備する事で回避策としたが、まったく透過的でないのは気に入らない。
かといって、chez等のようにStringをコードポイント列としてしまうと、FFIの
オーバーヘッドで更に気に入らない事になりそう。
コード解析して透過的に昇格/降格する事も考えたが、文字列操作で予測困難な
見えないオーバヘッドが挿入される事になる。

## `libs/rc2base`'s `Data.Integer.GMP` doesn't cover every `mpz_*` function

Deliberately scoped to two shapes only (see that module's own header
comment and `libs/rc2base/README.md`'s own section for the full
reasoning, not restated here): a single leading `mpz_t` out-parameter
with a `void` return, or a plain native return with no output
parameter at all. Several real GMP functions don't fit either shape
and are excluded rather than force-fit:

- `mpz_setbit`/`mpz_clrbit`/`mpz_combit`: mutate their *single* `mpz_t`
  argument in place, no separate `rop`/`op` at all -- confirmed as a
  real compile error when tried the same way as everything else
  (generates one argument too many). A real binding needs a wrapper
  that copies first (`mpz_init_set` into a fresh destination, then
  mutate that copy) -- the one case in this module that would need one
  at all.
- `mpz_invert`/`mpz_root`: a leading `mpz_t` out-param *and* a
  meaningful `int` return (invertibility/exactness) at once.
- `mpz_tdiv_qr`/`mpz_fdiv_qr`/`mpz_cdiv_qr`/`mpz_gcdext`: more than one
  output parameter (quotient+remainder together, or gcd+both Bézout
  coefficients).
- GMP's random-number API (`mpz_urandomb`/`mpz_urandomm`/etc.): needs
  an opaque `gmp_randstate_t` with its own init/clear lifecycle --
  separate design work, not an extension of this module's own
  direct-binding convention.

Not pursued further this round -- none of these came up against a real
need, and each would cost more than a one-line `%foreign` declaration
(the whole point of what's already there). Revisit if a concrete use
case needs one specifically.

## 融合変換のインジェクション
%transfor同等のものをバックエンドで持っておいてインジェクションできるようする。
  - CExpの時点で変換する
  - codeGenや、fastPack, fastConcatの読み替えもこの段階で処理できるようにする。
  - rc2baseに RC2 の名前で置いた定義も不要にしたい
    -> 上流に持っていけない定義をブラックリスト化し、不本意だがコンパイラ側で強制的に読み替えを行うようにできれば....

## %world 引数, Erased の引数を削除
  - 無駄でしか無いので消せるものなら消したい
  - 最適化効果は薄い。気分の問題でしかない。

## Lambda lift で欠落する情報の保全
現状、遅延評価についての情報が消えてただのクロージャになってしまう。
保全してメモ化やインライン展開をしたい。
新しい Lifted を定義し、NamedCExp からの Lamda lift を自分でやるしかないか？

  - 現在のLiftedでも、Force が無いだけでLazyは注釈として情報が残る
  - 特殊なクロージャを用意して型タグを使って実行時にメモ化を解決できる？
  - トップレベルの引数の無い関数はstaticで価をメモ化できる？
  - && や || のインライン化は調査済み・対応不要と判明(upstream自身の`%inline`
    プラグマとモジュールコンパイル時の`compileAndInlineAll`が、rc2独自の
    `Compiler.RC2.Inline`が動くより前にクロージャを跡形もなく消し去っている)。
    他の`Lazy`引数関数についても同様の
    upstream最適化が効くかは未調査。

## ファントム型やファントム関数の明示
トップレベル定義に 0 をつける。
実行時に存在しないからいいや、ではなく存在しない事を保証する

## thread-local-awareなdup/dop
マルチスレッド対応でdup/dropをアトミック操作にした結果、バスへの負荷増加やキャッシュ
破棄等と思われるペナルティによる性能劣化が観測された。
一つの案として、directiveによってシングルスレッド向け/マルチスレッド向けにコード生成
モードやランタイムを切り替える案が浮上した。それは後々対応するとして、そもそも
マルチスレッドであったとしても、あるオブジェクトが常に共有されている訳では無い事に着目
した最適化を行いたい。

具体的にはまずdup/drup_n/dropをアトミック版と非アトミック版に二重化する。
仮にあるランタイムオブジェクトがスレッド間で共有されているとしても、必ずしもその生涯
の全ての期間で共有されているわけではない事に着目し、「生成後、明らかに共有が発生しない」
区間では非アトミック版を使い、それ以外ではアトミック版と使い分ける事で負荷を軽減させる
事が可能なはずである。

そういう変数はそもそも大抵ネイティブ化されているはずなのでネイティブになれない値だけしか
恩恵を受けられない。

これをやるなら、エスケープ解析をして他スレッドに逃げる可能性の無い変数を割り出すのが先
だろう。

## foo(%1, %2)形式のFFI定義
%foreignの自由度が上がればラッパを書く手間が減らせる。RC2専用かつC関数名が%で始まっている場合
といった条件なら問題なさそう。%+数字を展開する時には周囲にカッコをつける必要がある事に注意。

%foreignはCompiler.Commonのパーサで単純にカンマ区切りをしているらしく一筋縄では行かない。
jsのlambda:の時にはヘッダもライブラリも必要ないので全体を一つの式としてしまっているらしい。


## idris2-curlの取り込み
インストール時にlibcurlへの依存が無ければrc2baseへ取り込んでも問題ないはず。
よく使う機能はバンドルとしておきたい。あるいはpure idris2のhttp clientを実装すべき？

## promiseの実装

## null定数の扱い
ランタイム側で定数にしてしまうべき。ポインタ比較演算と合わせて最適化を考える。

## 無制限のCAFメモ化(insertMemoize)が逆効果になる実例
`rc2/doc/caf-memoization.md`の設計方針は「ConstFoldで畳み込めなかった
0引数トップレベル定義は無条件に全部`RMemoize`で包む、コストはどうせ
1回のアトミックチェックだけだから安全側に倒して構わない」という
判断(同ドキュメント"Why not detect unsafePerformIO specifically"節)。
これは`unsafePerformIO`のような真の副作用を安全に扱うためには正しいが、
「アトミックチェック1回だけ」という前提が崩れるケースが実在する。

`libs/notcurses`の`NCKey.up = prim__nckeyUp`(単に別の0引数定義を
呼ぶだけの間接参照)が実例: `--directive dumprcexpr`で確認したところ
`memoize NCKey.up : Boxed`として、ヒープ確保+参照カウント+
`atomic_flag`によるCAS待ち合わせ(`caf_memoize.h`の
`idris2rc2_memo_boxed`経路)付きでコンパイルされていた。中身は
Cシム側で`static inline`にした純粋な定数返却関数で、メモ化さえ
無ければコンパイル時に即値へ畳み込まれていたはずのもの。「1回の
アトミックチェック」どころか、毎回の参照のたびに(初回はCAS+ヒープ
確保、以降は`done`フラグのアトミックロード)無駄なコストを払っていた。

対処(このケースでの回避策): `%foreign`宣言自体を`export`し、
「別の定義を呼ぶだけの0引数ラッパー」を挟まないようにすると
`insertMemoize`の対象(0引数`MkRCFun`)そのものから外れ、素の
foreign呼び出しに戻る。ただし今後もこの間接参照パターン
(`x = y`という0引数の単純委譲)は、意図せずBoxedメモ化を誘発しうる
罠として書き手側で気をつける必要がある。

**今後の検討課題**: `insertMemoize`側で「ConstFoldでは畳み込めない
が、ネイティブ型に収まる純粋な%foreign値」を検出してBoxedではなく
`idris2rc2_memo_native`(dup/drop無し)に倒す、あるいは「%foreignの
0引数プリミティブへの単純な委譲」自体をConstFold相当の早い段階で
透過的に解消してメモ化対象から除外する、といった軽量化の余地が
ある。ただし`unsafePerformIO`検出を避けた本来の設計意図(構文パターン
に頼らず安全側に倒す)を壊さない形にする必要があり、要調査。

## `RC.idr`のlookupEnv: `IsVar`証明による完全な全域化はIdris2の消去規則上不可能(2026-09-17)

`Compiler.RC2.RC`のPhase 1(`normalizeDef`)は`Compiler.LambdaLift`の
`Lifted vars`を歩く際、de Bruijn添字を`Env = List Int`という
`vars`と同じ長さである"べき"平場のリストで追跡しており、`lookupEnv`は
添字が範囲外だと`idris_crash`する安全網を持っていた。`LLocal`自体は
`(0 p : IsVar x idx vars)`という、`idx`が`vars`の正当な添字である
ことを示す証明を既に持っている(`Core.TT.Var`)。当初「この証明を
`normalizeDef`に通せば`lookupEnv`をクラッシュ無しの全域関数にできる」
という設計(「型で保証されていた不変条件を境界で捨てている」という
パターン)を実装しようとした。

**判明した事実**: `LLocal`の`p`フィールドはupstream側で`0`量(消去)
と宣言されている。Idris2は、消去された値のコンストラクタで分岐して
「分岐ごとに異なる実行時データ」を返す関数の定義を一貫して拒否する
(`Can't match on First (Erased argument)`)。これは実装の順序や
書き方の問題ではなく、`Core.TT.Var`の`nameAt`(`nameAt {vars = n ::
_} First = n`のような、まさに欲しかった書き方)が一見コンパイル
できることに惑わされたが、独立した最小再現で検証したところ`nameAt`
が許されるのは、返す値`n`が`vars`という**型レベルの添字そのもの**
から取り出せる場合に限られており、実行時に計算された値(今回なら
`Int`)を返す一般の関数では、引数が`p`ひとつだけの最小構成でも
同じエラーが再現した(`myCount : (0 p : MyIsVar n idx vars) -> Int`
相当)。つまり「消去された妥当性証明を使って、実行時データへの
安全なインデックスアクセスを型検査だけで保証する」という設計は、
`IsVar`がupstream側で消去されている限り、rc2側の書き方をどう工夫
しても届かない。

**実施した代替案**: `Env`を`List Int`から`Data.List.Quantifiers.All`
経由の`Env : List Name -> Type; Env vars = All (const Int) vars`へ
変更し、`env`の"長さ"を`vars`と型レベルで一致させた。これにより
`normalizeDef`/`LLet`/`normalizeConAlt`など、スコープを拡張する
すべての箇所で「`env`を`vars`の拡張と食い違ったまま構築してしまう」
というクラス全体がコンパイルエラーになる(実行時クラッシュではなく)。
ただし`lookupEnv`自体は結局`Nat`(`idx`)による再帰と、最終的な
"届かないはずのcatch-all"クラッシュ節を今まで通り残さざるを得ない
-- 縮小できたのは「`idx`自体が誤っている」場合だけに絞られた
クラッシュ到達可能性であり、完全な全域化ではない。

**今後の検討課題**: `Compiler.LambdaLift`自体(upstream)を変更して
`LLocal`の`p`を非消去にできれば真の全域化が可能になるが、upstream
コンパイラへの改変は本パッケージのスコープ外。あるいは、rc2独自の
Phase 0として`Lifted`を一度、非消去の`Fin`ベースの添字を持つ独自IRへ
変換し直す(証明を作り直すコスト)手もあるが、費用対効果は要検討。

## Performance: Closure Inlining and Immediate Expansion -- 静的に判明する適用は解決済み

  `partial`によるクロージャ生成とヒープ割り当てが高階関数・型クラス
  辞書で頻発する問題。このうち**呼び先が静的に判明する適用**は解決した
  (2026-09-24、`rc2/doc/const-closure-fold.md`の
  "Saturated application of a folded closure is now a direct call")。

  - `RCConstClosure`は捕獲値ゼロの真の葉なので`missing`が呼び先の全
    残りarityであり、**飽和適用は直接呼び出し**(`RAppName`)、
    **部分適用は直接のクロージャ構築**(`RUnderApp`)に書き換えられる。
    `Compiler.RC2.ConstFold`の`RApp`節と、`Compiler.RC2.LateInline`の
    `resolveConstClosureApps`(同じ形をConstFoldの後に作り直すため)の
    2箇所で実施。
  - idris2-lsp全体: `apply` 16,400 → 11,295、うち静的に判明する対象は
    4,842 → 19。実行時A/B(`tests/BenchConstClosureApply.idr`)で約21%
    高速化、対RefC 2.71x。

  **残るのは動的な対象のみ**(下記「定数引数による特殊化」を参照)。

## Performance: Higher-Order Function Specialization -- 一般の高階関数
  (`mapAppend`等)の引数クロージャの割り当てコストは`RCConstClosure`の
  定数畳み込み(`rc2/doc/const-closure-fold.md`)で解消済み。呼び出し先
  自体をコード複製で型特化する方向は別途調査済み(コードサイズ膨張の
  ため見送り、詳細は同ドキュメント参照)。クロージャ引数についての
  特殊化は`Compiler.RC2.SpecClosure`
  (`rc2/doc/speculative-closure-specialization.md`)で実装済み。
  インターフェース辞書経由のメソッド呼び出しに限定した特殊化は、
  下記「定数引数による特殊化」に設計を起こした(未着手)。

## Performance: `Integer` is always a heap GMP value -- the ceiling on native promotion

Surveyed 2026-09-24 while closing the native-promotion gaps
(`rc2/doc/dual-abi.md`, `native-type-inference.md`). Native promotion
is now essentially at its ceiling for the code it *can* reach: across a
whole idris2-lsp build the `op` nodes whose result stays `Boxed` are
dominated by types that have no native representation at all --

| op | count |
|---|---|
| `++` (String) | 462 |
| `cast-Integer-Int` | 244 |
| `+Integer` / `-Integer` | 232 / 180 |
| `==String` / `==Integer` | 65 / 35 |

`IDRIS2RC2_Integer` is an `mpz_t` in a heap cell unconditionally, so
every `Nat`/`Integer` operation allocates and refcounts even when the
value is tiny. A fixnum representation (small values as a tagged
pointer, promoting to GMP only on overflow) is the only thing that
moves this, and it is a runtime-representation change touching every
`IDRIS2RC2_Integer*` site -- a project in its own right, not an
extension of any existing pass. `rc2/support/rc2/idris2rc2_numeric.h`
already reuses a uniquely-referenced operand's own allocation in place
(`rc2/doc/rop-reuse.md`), which is the cheap half of the same problem.

Also still open, and genuinely small: 17 box-then-unbox round trips
survive in the test suite's own generated C (down from 210). They are
mixed cases -- a `case` one of whose arms is Boxed, a literal minted by
a pass other than `LateInline`, an `opBox` feeding `sqrt`. Low value.

## Performance: constructor return values are always heap cells -- return small constructors by value (struct return)

Important. A function returning a constructor always heap-allocates it,
even when every caller immediately pattern-matches the result and drops
it. The dominant case is upstream's own `Core a = IO (Either Error a)`:
every `Core` action returns a fresh `Left`/`Right` cell that its caller
destructures on the spot. Across a whole idris2-lsp build (2026-09-25,
final `dumprcexpr`), 17,458 `let v = ... ; case v of` pairs exist; the
bound value is a direct `call` in 7,021 of them and a DualABI `callRep`
in 357 more -- the call-boundary share this item targets. (The 1,796
whose value is a `con` built in the same function need no call-boundary
change at all; they are the separate, intraprocedural
case-of-known-constructor fold.)

Design and implementation (2026-09-25): `rc2/doc/struct-return.md`,
opt-in with `--directive structreturn`. A
new DualABI stage returns a constructor with at most one field as a
fixed 16-byte `{tag, f0}` struct in registers; the Boxed wrapper
materialises the cell for every other caller. On idris2-lsp that covers
8,039 functions and 3,648 of the 4,959 call-then-`case` pairs; a
hand-written model of an `Either` chain runs 17-38% faster. `IO` is
already erased (`Core` returns a bare `Either`), reuse analysis already
limits today's cost to one malloc per chain, and tail calls between
eligible functions form no cycle, so they can become direct C calls.
Implemented through the call-site rewrite; `tests/BenchStructReturn.idr`
runs 30% faster and allocates half as often. Left: decide whether to
turn it on by default, which wants a run-time measurement on a real
workload (idris2-lsp cannot reach C generation yet); constructors of
two to four fields (about 2,200 functions on idris2-lsp) and native
payloads are further extensions.

## Performance: constructors built and matched in the same function -- rest of the escape analysis

Since 2026-09-25: `ConstFold` folds a `case` on a non-escaping
constructor and an `apply` of a non-escaping partial application,
`Compiler.RC2.PushCon` pushes a `case` into the tails of a value whose
arms end in constructors, and `Compiler.RC2.Inline` inlines loop-free
single-caller callees before RC annotation so their constructors meet
those folds. See `rc2/doc/constructor-escape-analysis.md`.

The "Early inline" stage now also runs `LateInline`'s single-caller
splicing before RC annotation (no CAFs, no callees in a call cycle).

Still open: the shapes the later `LateInline` run still creates after
RC annotation (72 shape-A and 1,189 shape-B sites across idris2-lsp),
from loop-bearing callees and ones that become single-caller only
later. The RC-aware fold for them exists but is opt-in
(`--directive latepushcon`): it leaves the static constructor count
unchanged on idris2-lsp, and whether its fresh-tail savings matter at
run time needs a real workload to measure. Loop-bearing values (168
sites) aren't pushed into at all yet.
