# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## IR: `dup`・`drop`・`postDrop`の対象を変数IDだけにする(アイデア)

`RDup`・`RDrop`・`postDrop`・`prologueDrop`・`RReuseOffer`の`dupOnShared`/`dropOnUnique`などは、
今は`RCLocal`のリストで、定数(`RCNull`・`RCErased`・`RCWorld`・畳み込み済みの定数)も型の上では入れられる。
しかし数えるのは変数だけで、定数への`dup`/`drop`は何もしない。実際に入り込んだ例が
`DualABI.postDropFor`(定数の引数、`NULL`型のものを含めて`postDrop`に入れていた。直した)で、Emitが
`idris2rc2_drop(NULL)`を出し、IRのダンプにも`postDrop= [[erased]]`と残っていた。

案: これらのフィールドの型を`List Int`(変数ID)か、`RCLoc`だけを表す型にして、定数を入れられなく
する。パスが定数を入れる間違いが型エラーになり、Emitの`varName`の定数の分岐(`RCConst`・`RCConstCon`・`RCConstClosure`は
`/* [rc2] unreachable ... */`を返す)と、各パスの`RCLoc`の場合分けも要らなくなる。`RCExp`の
構成子の型が変わるので、`postDrop`などを読み書きする全パス(`RC`・`DualABI`・`Loop`・`MutualLoop`・
`DupMerge`・`PushDown`・`Reuse`・`DeadVars`・`FunDedup`・`Emit`)に影響する。`RCConstCon`の
`argsConst`と同じ要領(消去される証明)でも書けるが、`List Int`のほうが単純。

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


## Compatibility: `show` of a `Double` picks exponent notation differently from Chez (found 2026-09-27)

Both print the same value, in different notation:

| value | Chez | rc2 |
|---|---|---|
| `1.0e10` | `1e10` | `10000000000.0` |
| `123456789012.5` | `1.234567890125e11` | `123456789012.5` |
| `2.305843009213694e18` | `2.305843009213694e18` | `2305843009213694000.0` |
| `1.0e-5` | `1e-5` | `0.00001` |
| `1.0e21`, `1.0e-7`, `1.0e9`, `0.001` | same | same |

- **Chez** (`number->string`) switches to exponent notation whenever it
  is the shorter spelling.
- **rc2** does so only at 1e21 and above, or below 1e-6, as JavaScript
  does.

Only programs that print large or small doubles see it. Found when
comparing `Test112Numeric/ImmediateInts.idr`' `Int` to `Double` casts against Chez;
that test now avoids such values. Decide whether rc2 should follow
Chez's rule; nothing in Idris itself fixes the format.

## Upstream stdlib `%foreign` declarations with no C/RefC backend at all

Surveyed every `%foreign` declaration in `idris2-src/libs` (206 across
27 files, `base`/`prelude`/`contrib`/`network`) for ones carrying no
`"C:..."`/`"RefC:..."` alternative whatsoever. Anything without a
C-tagged alternative is a function the *pinned reference*
`idris2 --cg refc` itself cannot call at all -- not an rc2-specific
gap. Four such spots found, all upstream:

- **`Data.Buffer`**: `setInt8`/`getInt8`/`getInt16`/`setInt64`/
  `getInt64` -- fixed upstream (#3873 adds `"RefC:..."` tags that name
  rc2's own runtime symbols); the `Data.Buffer.RC2` patch module is gone.
- **`Data.Double`**: `unitRoundoff`/`epsilon`/`nan`/`inf` -- patched,
  see `libs/rc2base/README.md`'s "`Data.Double.RC2`" section.
- **`System.Random`** (contrib): `prim__randomBits32`/
  `prim__randomDouble`/`prim__srand` (backing the whole module) remain
  entirely unimplemented on any C backend. Not a `%foreign_impl` patch
  onto them (unlike `Data.Double` above) -- see
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

## `dlsym`のシンボルを`Data.Rel`の`Fun`としてクロージャにする(アイデア、2026-10-19)
rc2が作ったDLLなら、`dlsym`が返す関数ポインタをrc2ランタイムの`idris2rc2_mkClosure(fn, arity, 0)`でクロージャにし、
目的の関数型へ`believe_me`すれば、ふつうの関数値として使えそうだ。アリティは`Data.Rel`/`Data.Fun`の
`Fun ts r`の`ts`(型のリスト)の長さから取れる。例: `symbolFun : (ts : Vect n Type) -> (r : Type) -> AnyPtr -> Fun ts r`。
先にABIを固定しないと始められない。詰める点:
  - `fn`に入れてよいのは全引数がboxedのwrapperだけ。DLLが出すシンボルがwrapperかworkerか、その名前が安定しているか。
  - 世界トークン: `r`が`IO`のとき、アリティを1つ足すか。IRでの扱いは`rc2/doc/world-erased-marks.md`を参照(世界は実行時に常にNULL)。
  - 消去される引数(型引数・暗黙引数)がシンボルの引数に残るか。`ts`の数え方の規則。
  - ランタイムの共有: DLLが自前のランタイムを持つとヒープと参照カウントが二重になる。ホストのランタイムをリンクして使う構成が要る。
  - `Nat`/`Integer`などの表現が、同じ版のコンパイラで作ったものに限って揃うこと。
着手の前に、この条件を`rc2/doc`にABIとして書き出す。

## ファントム型やファントム関数の明示
トップレベル定義に 0 をつける。
実行時に存在しないからいいや、ではなく存在しない事を保証する

## thread-local-awareなdup/drop
実装済み: プロセス全体のフラグでatomic/非atomicを切り替える方式(`rc2/doc/hybrid-refcount.md`、計測の表も同ドキュメント)。
missing-containersで-16%、sortで-23%。残りの案は、逃げないと判っている変数を非atomic版に固定するエスケープ解析で、
上限はmissing-containersで8ポイント。関数内で閉じた解析は、idris2-lspの297,911箇所中57箇所しか固定できず無意味。
関数の引数を通して連鎖させる粗い全体解析(複製なし)も、missing-containersで-1.7%にとどまり打ち切った。
やるなら、スレッドへ逃げうる値を追う全体解析と、引数がスレッドに閉じている呼び出し元向けの関数の複製が要る。

## 既存のシムをCExprで置き換える: 残り
`libs/rc2base`ほかは置き換え済み(`rc2/doc/ffi-cexpr.md`)。残したシム: regexのcompile/exec/free/group_*(TLS状態・確保)、
TextBufferの確保系、string_byte_slice、double_convert、xoroshiroの`*_sys`、concurrency_util。
`System.Posix.Directory`の`DirEnt`は不透明型+PrimIOのCExprアクセサだが、`Struct "struct dirent" [...]`と
`%cg rc2 externStruct=struct dirent`でも扱える(確認済み、`Test120CStruct/CgSpacedStructName`、`rc2/doc/c-struct-support.md`の Tips)。
切り替えるかは別の判断。`_GNU_SOURCE`が要る宣言は、環境変数`IDRIS2_CFLAGS=-D_GNU_SOURCE`でコンパイルする、と各宣言の
doc commentに書いてある。生成コード側で定義する機能は作らない。

## FFI関数からの構造体返し
`%foreign`の戻り値型が`Maybe`/`Either`/タプルの時、C関数が`{tag, f0, ...}`形式の構造体を
値で返し、それを受け取れるようにしたい。今はC側でコンストラクタのセルを組むか、複数回の呼び出しに
分けるしか無い。DualABIのworkerの構造体返し(`rc2/doc/struct-return.md`)と同じ形にすれば、
呼び出し側がそのままネイティブに分解できるはず。

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
`LLocal`の`p`が上流で`0`量(消去)なので、証明で分岐して実行時の値を返せない。`Env`を`All (const Int) vars`にして
長さの食い違いはコンパイルエラーにしたが、`lookupEnv`の範囲外クラッシュ節は残る。完全な全域化には、上流の
`Compiler.LambdaLift`で`LLocal`の`p`を非消去にするか、`Lifted`を`Fin`添字の独自IRへ変換し直す必要があり、費用対効果は要検討。
調査の詳細: `rc2/doc/lookupenv-totality.md`。

## Performance: box-then-unbox round trips left after native promotion
テストスイートの生成Cに17件(元は210件)。混合の`case`、`LateInline`以外が作るリテラルなど。再計測(2026-10-13、idris2-lsp)でも、
手軽に取れるネイティブ昇格は残っていない(`LateInline`の後に`ConAltNative`をもう一度走らせる実験は冪等でなく、
冗長な二重化が830件増えたので破棄)。優先度は低い。

## Performance: closure-returning functions with mixed tails

World arity raising (`rc2/doc/world-arity-raising.md`) raises only a
function whose every tail builds a closure missing one argument.
Estimated 2026-09-26 (that doc's "Raising functions whose tails mix
closures"): 839 idris2-lsp sites apply the result of a function whose
tails mix closures; about 300-570 would save a closure, with next to no
new struct-return sites -- one to two tenths of the pass itself. If
done, start with callees whose tails are only `partial`s and `apply`s
(292 sites, only the `apply` rule on top of the pass). Low priority.

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

## Robustness/performance: tail recursion modulo constructor (TRMC), what remains

Phases 1 to 3 are done: self and mutual recursion, with holes at any
field index and, of several recursive fields, the last-evaluated one.
`rc2/doc/trmc.md` has the design and the measured results. Still open:

- **Mutual sites reached back only through a non-tail call.** Most of
  the 77 mutual sites left in idris2-lsp, e.g. `substEnv`'s `CApp`,
  whose last field maps the arguments through a `mapAppend` clone that
  calls `substEnv` per head.
  Their depth is the term's, not a list's.
- A raw hole address (phase 4) and holes under a `case` in a field were
  measured and dropped: `trmc.md`, "Phase 4 measured, not pursued".

## Performance: closure-valued loop parameters, beyond difference lists

The difference-list shape (`c . (y ::)`, as in `sortBy`'s `splitRec`)
is done; `rc2/doc/closure-accumulator.md` has the design and results.
Nine such loops remain in idris2-lsp, in three other shapes:

- **`c (e x)` for an arbitrary pure `e`.** One loop:
  `Data.Vect.foldr`'s `foldrImpl`, `go . f x`.
  - The chain of closures is already a list of frames. Applying it
    could unwind iteratively instead of recursing.
  - That needs an IR `case` over a closure: test its function, read its
    captures. It is sketched under "Later" in the design doc.
- **Continuation passing.** Six loops: the three `treeToList'` and the
  scheme backends' `applyLams`. The continuation calls the traversal
  again and wraps its result, so there is no single hole to fill.
- **Other.** Two loops: `mkClosedElab`, `ProcessData.shaped`.

`sortBy` was the one that crashed (`KNOWN-BUGS.md`). Whether the map
`toList` traversals can build long enough continuation chains to
overflow has not been measured.


## Performance: `sort` against Chez -- 残る原因(測定 2026-09-26)
`Data.List.sort`(1M要素の`Int`)は4.18s(Chez 1.23s)だったが、`DeadArgs`・比較関数の特殊化・ハイブリッドrefcount・即値`Int`で
大きく縮んだ。経緯と実験の表は`rc2/doc/sort-vs-chez.md`。残る内訳(`DeadArgs`後3.21sの時点で、非atomicな`dup`/`drop`と
mimallocを併せた1.81sの実行):
- TRMC化した`mergeBy`のループが42%。うち約2/3はメモリ待ち(リストのセルのフィールドの読み込み37%、比較器へ渡す`dup`のために
  boxedな`Int`のrefcountに触る30%)。
- 比較関数の呼び出し経路(`applyClosureN`、`dispatchFn`、wrapper、worker、`trampoline`)が約28%(1回約25ns、確保なし)。
- `split`が8%、後始末が5%。
- glibcの`malloc`(mimallocで-33%)。次の「小オブジェクトのアロケータ」を参照。

## Performance: a small-object allocator in the runtime (measured 2026-09-27)

`idris2rc2_alloc` is plain `malloc`. Every cell, box and closure goes
through glibc, which is the largest remaining cost on list-heavy code.
The table compares allocators swapped in with `LD_PRELOAD`, which any
user can do without the compiler's help:

| | glibc | mimalloc |
|---|---|---|
| map/filter, 300k x 50 | 6.73s | 1.08s |
| `sort`, 1M `Int`s | 2.45s | 1.63s |
| `idris2-missing-containers` | 6.46s | 6.05s |

- **Why glibc is slow here:** tearing down a long list pushes its cells
  onto glibc's LIFO fastbins in scattered order. The next allocations
  pop them in that order, and each pop reads the next chunk's header,
  a cache miss. `_int_malloc` was 33% of map/filter's profile, almost
  all on that one load: 106M cache misses against mimalloc's 20M.
  mimalloc keeps each page's free cells together, so consecutive
  allocations stay close.
- **Raising glibc's tcache** (`GLIBC_TUNABLES=glibc.malloc.tcache_count=65535`)
  made map/filter slower (8.27s).
- **`aligned_alloc` was a slow path in mimalloc.** With it,
  `missing-containers` took 7.16s under mimalloc, slower than glibc.
  `idris2rc2_alloc` now calls `malloc`. Under glibc that saves about 2%
  (best of 7: 6.58s to 6.46s); map/filter and `sort` are unchanged.

**Idea:** size-class pages inside the runtime, allocated in order and
freed back to per-page free lists, as mimalloc does. That would get
the locality without an external dependency. The open problems:
- **Threads.** A page per thread avoids locks, but a cell freed on
  another thread has to go back to its owner (mimalloc's delayed free
  list). `idris2rc2_threaded` could keep the single-threaded path
  lock-free.
- **Returning memory.** Empty pages must go back to the OS, or a peak
  of one size class is never reusable by another.
- **Sizes.** Which classes, and what falls through to `malloc`: big
  closures, strings, GMP.
- **Interaction with reuse.** `reuse=` already recycles a dying cell
  in place; the allocator only sees what reuse misses.
- **Foreign code** that frees or reallocates runtime values.
  `idris2rc2_free` and teardown are the only exits today; verify that
  nothing else calls `free` on a value.

**Another case (2026-09-27): `idris2-missing-containers`' `read`.**
It is the one step of that benchmark still slower than Chez: 0.378s
against 0.338s, best of 3. Allocation dominates it:
- `malloc`, `free` and teardown are 38% of its profile;
- under mimalloc it takes 0.346s, level with Chez.

Two sources of allocations:
- **Each character of a hashed string.** `Hashable String` walks the
  key with `Data.String.Iterator.uncons`. The runtime's
  `stringIteratorNext` returns a fresh `Character c it` cell per
  character, which the caller matches and frees at once.
- **Each lookup.** The IO actions `IOHashSet` passes around are
  closures, and it builds `Op`, `Maybe` and pair cells.

Returning `uncons` by value would remove the first, but only by giving
one foreign function special treatment in the compiler, which rc2 does
not do. An allocator that makes small short-lived cells cheap covers
both sources.

## 安全性: 証明・線形型で実行時エラーを型エラーへ移せる箇所(調査 2026-09-28)

`rc2/src`の`idris_crash`(4箇所)、`InternalError`
(約35)、「起こらないはず」とコメントだけで守っている不変条件を
洗い出した。既に型で守っている先例は`RCConstCon`の
`{0 argsConst : All IsAnyConstLocal args}`と`IsConstLocal`
(`RCExp.idr`)、`RC.idr`の`Env vars = All (const Int) vars`。
**注意**: 消去された証明(`0`)で分岐して実行時の値を返すことは
できない(上の「`RC.idr`のlookupEnv」節)。以下はどれもその制約を
避けられる形、つまり「データの形そのものを型で絞る」か「非消去の
添字を持つ」形で考えている。手軽なものから順に並べる。

### A. 小さく閉じた置き換え(1箇所ずつ、他の変換へ波及しにくい)

- **コンストラクタのarity/tagが16bitに収まる**(`Emit/Util.idr:127`)。
  上流から来る値なので証明は作れないが、`ConInfo`を受け取る所で一度
  検査して、検査済みを示す型(`Bounded16`など)に包めば、Emit側の
  例外を境界の1箇所へ寄せられる。
- **FFI型の`cTypeOfCFType`/`extractValue`/`packCFType`の
  catch-all**(`Emit/Util.idr:1613/1655/1703`)。`%foreign`を受け
  取った時点で`CFType`をrc2が扱える部分集合の型(`RC2CFType`)へ
  変換し、非対応はそこでユーザー向けエラーにする。以降の3関数は
  全域になる。
  **注意**: 受け取った時点(`DeadCode`より前)でエラーにすると、プログラム
  が使わない`%foreign`宣言(標準ライブラリのものなど)に非対応の型
  (`CFForeignObj`など)があるだけでビルドが止まる。変換を`DeadCode`の後へ
  回しても、参照はされるが実行時には通らない分岐の中のFFIは残る(今も
  `idris_crash`で落ちる)。そこで変換結果を`Either`(非対応の理由)で持ち、
  非対応のFFIはコンパイルを止めずに「呼ばれたらメッセージを出して止まる」
  Cの関数を出力する(必要ならコンパイル時に警告も出す)。C生成の3関数は
  変換に成功した型だけを受け取るので全域になる。

### B. IRの型に不変条件を載せる(複数パスに波及、効果大)

- **Rep(boxed/native/RetN)で`RCExp`を添字付けする**。現状、
  `Emit.idr:945/971/1018`(native文脈にboxedが来た)、
  `Emit/Util.idr:1006`と`Emit.idr:110`(RetNがboxed文脈に来た)、
  `Emit.idr:765/767`(RMemoizeにnative)がすべて「表現の食い違い」の
  実行時検出。`RLet`が持つ`Rep`と、`RV`/`RAppNameRep`などが生む値の
  表現を型レベルで一致させれば、このクラス全体がコンパイルエラーに
  なる。ただし全パスが`RCExp`を作り替えるので改修は大きい。まず
  `emitNativeValue`に渡す部分式だけを別の型(`NativeExp ty`)に
  切り出す、という段階的な入り方が現実的。
- **`RLoopContinue`は`RLoop`の内側にしか現れない**(`Emit.idr:267`)。
  `RCExp`を「ループの中か」(あるいはループ引数の`List Rep`)で添字
  付けすれば、`RLoopContinue`の引数の個数・表現もループ引数と一致
  することまで保証できる。`Loop.idr`/`MutualLoop.idr`/`Trmc.idr`が
  作る側。
- **`emitRC`に届かないはずのノード**(`Emit.idr:1082`「not
  intercepted by emitInto's dispatch」)。文(`RLet`/`RCase`系)と
  値を生む式を別の型に分ければ、ディスパッチ漏れが型エラーになる。

### C. 線形型(量1)で資源の扱いを守る

- **参照カウントのdup/drop対応**。Phase 2(`annotate`)が各変数を
  「所有」か「借用」かに分け、`postDrop`/`RDup`/`RDrop`/
  `RReuseOffer`の`dupOnShared`/`dropOnUnique`へ振り分けている。
  「所有する変数はどの経路でもちょうど1回消費される(使うか、drop
  するか、reuseに渡す)」は線形性そのもので、rc2の正しさの核心。
  ただし`Core`モナドは線形に対応しておらず、`SortedSet`で所有集合
  を持つ今の書き方を線形な所有トークンへ直すのは大改修になる。
  段階案: (1)まずPhase 2の出力を検査する独立した検証パス(各経路で
  所有変数の消費回数を数える)をデバッグ用に作る、(2)それで
  検出できる不具合の種類を見てから、線形型での作り直しを判断する。
- **Emitの「後で出すdrop」(`rcVarToBoxedC`などが返す`pending`)**。
  インライン展開した式が借りたboxed値のdropを、呼び出し側が必ず
  1回だけ出す約束になっている。`pending`を線形な値として返せば、
  捨てた・二重に出した、がコンパイルエラーになる。ただしこれも
  `Core`の中なので、純粋な部分に切り出せるかの調査が先。
- **`CFPtr`の寿命**(上の「native (unboxed) `Ptr`/`CFPtr`」節)。
  unboxedにしたときに失われる寿命の追跡を、rc2base側の線形な
  ハンドル型で補えないか。rc2のコンパイラ本体ではなくライブラリ側
  の課題。

関連: 上の「ファントム型やファントム関数の明示」(量0で実行時に
存在しないことを保証する)も同じ方向の課題。

## FFIでまだ扱えない`CFType`(調査 2026-09-29)

`Compiler.RC2.Emit.Util`の`cTypeOfCFType`/`extractValue`/`packCFType`と、
`%foreign`の戻り値検査(`RC.idr`の`checkForeignReturn`)、`%export`の型の
認識(`RC2.idr`の`exportNfToCFType`)から洗い出した。

### `%foreign`(Idrisから C を呼ぶ)

| `CFType` | 引数 | 戻り値 | 今の挙動 |
|---|---|---|---|
| `CFForeignObj` | 不可 | 不可 | 3関数のどれにも節が無く、catch-allの`idris_crash`でコンパイラが落ちる |
| `CFFun` | クロージャの構造体へのポインタが渡る | 不可 | 引数: Cの関数ポインタではないので、C側から直接は呼べない(`idris2rc2_applyClosure`を使うシムが要る)。戻り値: `checkForeignReturn`がエラーにする |
| `CFStruct` | ポインタのみ | ポインタのみ | 構造体の値渡し・値返しはできない(値返しは上の「FFI関数からの構造体返し」) |

### `%export`(Cから Idrisを呼ぶ)

| `CFType` | 引数 | 戻り値 | 今の挙動 |
|---|---|---|---|
| `CFBuffer` | 不可 | 不可 | `exportNfToCFType`が認識しない |
| `CFForeignObj` | 不可 | 不可 | 同上 |
| `CFUser` | 不可 | 不可 | 同上 |
| `CFFun` | 不可 | 不可 | 同上 |
| `CFGCPtr` | 可 | 不可 | `validateExport`が戻り値を拒否する |

`CFForeignObj`でコンパイラが落ちる件は、上の「安全性」の節の「FFI型の
catch-all」(扱える型への事前変換と、非対応の`%foreign`を呼ばれたら止まる
スタブにする案)で解消する。

## コンパイル時間: リファクタリング案(調査 2026-09-29)
idris2-lspを`--timing 3`で`--cg rc2`ビルドした時点の大きい順は Early inline 6.66s、Late inline 4.71s、
RC annotate+Reuse+ConAltNative 3.03s、DualABI 3.02s、Inline 1.54s、ConstFold 1.32s(C生成は既知の
`%foreign declaration ...unsafeVectorToList has no implementation rc2 can call`で止まるので、その手前まで)。
その後、構造体返しのplan(1.61s→0.69s)、呼び出しの表の共有(Early 6.66s→6.42s、Late 4.71s→4.43s)、
展開0件のラウンドの省略を入れた。残り:

- **計測を分ける。** 「RC annotate + Reuse + ConAltNative」は3パスの合計なので、パスごとの合計時間を足し上げて最後に1行出す。
  DualABIの残りはprune plan 0.35s、rewrite 0.44s。C生成まで通る大きなプログラムを計測用に決める(idris2-lspは届かない)。
- **Late inlineの固定費。** `pruneDeadDefsCached`が毎ラウンド到達可能な全定義(約2.5万)を辿り直す(ラウンド3〜5で各約0.2s)。
  案: (a)刈り込みを差分にする(計約0.3sの見込みで、複雑さに見合わず見送り)、(b)`Name`を整数に置き換える(`analyse`にも効くが
  1000行のモジュール全体に触る)、(c)展開数が一定以下で打ち切る(出力が変わるのでベンチマークで確かめる)。
- **試して見送り。** 再畳み込みを展開された定義だけに限る(1.11s→0.97sで、出力が変わった)。第1ラウンドの処理順に刈り込み前の
  Tarjanの結果を流用する(6.06sまで縮んだが出力が変わった。`Carried.order`のコメントは処理順を「結果を変えない目安」としているが、
  実際には結果に効く)。
- **既知の落とし穴の点検。** `code-style-Idris2.md`の「性能上の落とし穴」(`List`の`concat`/`concatMap`、`union`の引数の向き、
  `where`で束縛した集合の再計算、部分木の繰り返し走査)が残っていないか、重いパスから順に見る。

## テストの穴(監査 2026-09-29)
- 失敗すべきプログラムのテストの残り: `RC2.idr`の`validateExport`の他の経路(引数が21個以上、アリティの不一致、関数でない定義)、
  `getField`のフィールド違いと名前がリテラルでない場合(Idrisのフロントエンドが先に型エラーにするので、rc2に届く形があるかも未確認)。
- インクリメンタルコンパイル(`--inc rc2`)のテストが無い。verifyは全体コンパイルしか試さない。
- 大きな外部プログラムがverifyに無い。idris2-missing-containersはbench.shでしか動かさない。idris2-lspのIRをlintにかける手順は
  スキル`rc2/.claude/skills/lint-lsp-ir`にある(任意実行、約4分)が、verifyには入れていない。
- Test113DeepRecursionは、まとめたことで元のテストとIRが違う(`mod`がワーカー呼び出しになる、`mergeBy`の特殊化の展開が変わる)。
  100万段でCスタックが溢れないことは実行で確かめている。同じ形を狙うなら分け直す。

## gen-env.shの削除とドキュメントの修正

**状態: 当面放置(小さな作業)。** `gen-env.sh`は不要なので削除する。`env.sh`は残す。
参照している記述を直す: `README.md`、`README.ja.md`(ja ミラーにも同じ参照がある)、
`AGENT.md`(layout 節の「env.sh / gen-env.sh」)、`KNOWN-BUGS.md`。
`rc2/tests/bench.sh`、`rc2/tests/verify.sh`、`.claude/skills/run-idris2-rc-cg/`の
`smoke.sh`と`SKILL.md`にも`gen-env`の参照が残っているので、削除前に`grep -rn gen-env`で洗う。


## 比較の入れ子の合成: 未実装の残り
`Compiler.RC2.CmpMerge`は実装済み(`rc2/doc/native-type-inference.md`の"Merging nested comparisons"、計測もそこ)。残り:
- `compare_Ord_Int`/`compare_Ord_Integer`が展開されないのは`delegatingThreshold`のため(24のままでは残り、40にすると全部展開される。
  書き換え後のサイズは25から40の間)。idris2-lsp全体で24にすると3.3%増える(`rc2/doc/inlining.md`)ので、しきい値を上げずに
  `compare_Ord_*`だけを許す個別の扱いを検討する。
- `let`+`case`の未融合は8組。`case`の対象が入れ子の`let`の末尾の比較になる形で、`PushCon`の「ブロックの末尾への`case`の押し込み」を
  比較にも広げるのが候補だが、8組では見合わない。
- 同じ結果を返す複数の`case`の枝(`0 -> 10; 1 -> 10; _ -> 10`)を1つにまとめる処理は未実装。`ConstFold`の`case`の簡約の近くが候補。
  否定を伴う変形(`cmp <`を`cmp >=`にして枝を入れ替える)は、DoubleのNaNで成り立たないので入れない。

## 借用推論(borrow inference): 計測して保留(2026-10-07、数字は2026-10-14)
今の形では導入しない。annotate前の推論は、借用を決める事実(`Reuse`・`MutualLoop`/`Loop`・`DualABI`・`LateInline`)が
annotateの後で決まるので位置が合わない(借用にできた引数は5.9%、呼び出し側の`dup`の削減は0.6%)。annotate後(最終IR)で数えても、
idris2-lspの静的な純減は全`dup`/`drop`の3.2%で、ループの中の重みはマイナス(実行時には逆効果になりうる)。計測の詳細:
`rc2/doc/borrow-inference.md`。再検討するなら、`callRep`だけのwrapper定義が「ループでない末尾呼び出し」で除外されている点
(実行時にはtrampolineされないので規則が厳しすぎる可能性)と、`case`のフィールドの`dup`を借用で扱えるか(再利用と衝突しうる)から。

## dup/dropの押し込み: 残り(D)
`PushDown`(`rc2/doc/pushdown.md`)ほかで、`case`の上の`dup`が枝の`drop`に打ち消される形(A)、`dup`と直後の`postDrop`の対(B)、
別名`let`のdrop(C0)は対応済み。残りは**D: フィールドの`dup`の後に親の`drop`が来る形**(`tools/rcexpr-lint --pushdown-stats`、
idris2-lsp、PushDown後で13,421箇所・20,827操作で全`dup`/`drop`の8.1%、ループ内9,914操作。うち「枝が新しいconを作る」5,027箇所、
「作らない」8,394箇所)。親が一意なら両方消せるが、実行時の一意性判定が要る。設計メモ(未実装):
  - 案1(本命): 既存の`reuseOffer P dupOnShared=[フィールド] dropOnUnique=[]`+直後の
    `releaseReuse P`をそのまま使う。`Reuse.resolveAlt`は「枝が同名のconを作る」ときだけ
    `reuseOffer`を出しているので、その条件を外して(または別条件で)出す。一意なら殻を
    返すだけ(フィールドのdup k回とdropのdec k回が消える)、共有ならこれまでと同じdup+drop
    +判定1回。新しいIRノードも`Emit`の変更も要らない。費用は、判定のぶんのコードと、共有が
    大半の場所での判定のオーバーヘッド。`Reuse.resolveAlt`のコメントに、死んだオファーを共有パスに
    畳むとrefcount操作が増えたという逆向きの計測があるので、静的な行数ではなくベンチ
    (`bench.sh`)で実行時の効果を測ってから採否を決める。
  - 案2: 借用(フィールドを親から借りたまま使い、親のdropを後ろへ送る)。全ての呼び出し側と
    再利用に影響し、保留中(上の借用推論の節)。
  - 型付き定数フィールド(`noboolfield`)は`dup`/`drop`が既に無いので対象外。`ConAltNative`の
    シャドウが再導出するdropとは`reannotateFieldOwnership`で整合を取る必要がある。
  - `PushDown`との順序: 案1を先に適用するとAの`dup f; drop P`の形が消えるので、Aで消せる分
    (親を後ろへ送って枝ごとに相殺)が減る。Aが先に済んだ今は、残りのDが案1の対象。
  - 未確認: 案1の実行時の一意率(ループ内の重み)、`reuseOffer`が増やすCコード量。

優先順はD(A、B、C0は済み)。未確認: Dの親が実行時に一意か、実行回数での重み付け。
Aの残り(`let`/`cmp`をまたぐ形)は、`let`の値が呼び出しなので、親のdropを呼び出しの後ろへ
送ると呼び出し先で一意性が落ちうる(インプレース更新がコピーになる)ため見送った。

## Bool: nativeにする残り
段階1〜3b(返り値、`case`の分岐、コンストラクタフィールド)は実装済み(`rc2/doc/dual-abi.md`の"Bool return"ほか)。残り:
- `MutualLoop`が畳まなかった末尾呼び出しの環は、返り値がBoxedのまま。
- やらない: 消費側の0/1だけを根拠にパラメータを`Bool`と推論すること。
- 再現しなかった件(2026-10-08): 狭い版の最初の2回のidris2-lsp実行で、1か所の`reuseOffer ... dupOnShared`のidが`v261316`でなく
  `v271316`と出た(差は+10000の1か所)。再発したら、実行直後の`idris2-rc2`の更新時刻とコミット、出力のmd5、同じディレクトリを
  使っていた他のプロセスの有無を残すこと。

## MutualLoopが作る名前のマングリング: モジュールをまたいで一意でない(2026-10-08)

`MutualLoop`が畳んだ関数の名前は`MN "rc2_mutualLoop" i`で、`i`はMutualLoopの
パスごとに0から数える`FreshId`の連番(`MutualLoop.idr`)。名前にモジュール名が
入らないので、増分コンパイルで別々のモジュールが同じ`rc2_mutualLoop_0`を作りうる。
今は畳んだ関数が`static`なので衝突しないが、MutualLoop版のstruct return
(`--directive nomutualstruct`で切れる)のworker(`idris2rc2_worker_rc2_mutualLoop_N`)
にも同じ名前の規則があり、`Util.isMutualLoopWorker`で名前の接頭辞を見て`static`に
している。これは回避策で、根本の直しではない。

- 名前を接頭辞で見分けるのは壊れやすい(命名規則を変えると静かに`static`が外れて
  リンクエラーか、最悪は別モジュールの同名の関数に静かに結びつく)。
- `static`のworkerは、他モジュールからは呼べない。畳んだ関数の呼び出し元が別モジュールに
  なる設計に変えると破綻する。
- 増分コンパイルでは未検証(同名のworkerが2つのモジュールにある状態を作って確かめていない)。

直し方の候補: (1) 名前にモジュール名かコンパイル単位のハッシュを入れて、
`static`に頼らず一意にする。(2) 畳んだ関数とそのworkerを、名前でなく`Def`の属性
(file-local)として持たせ、`Emit`がその属性で`static`を決める。(1)の方が単純。
どの`MN`/`UN`をDualABI・Loop・Specializationなどが作るかの総点検も要る
(同じ連番方式のものが他にもあるはず)。

## reuse: `let`値内のネスト claim の残り (2026-10-08)

**状態: 調査済み・低優先(着手しない)。** 残りは数十〜数百箇所ずつで、どれも設計変更を
伴うのに対し、dead offerの多くは「ユニーク親の高速パス」(フィールドをdupせず移し、
殻だけをfreeする)で、殻の解放は既に行われている。見直すのは、reuseの不足がベンチマークや
メモリ使用量で実測できたとき。

`noreusenested`で切り替えられる`let`値内claim(`rc2/doc/reuse-analysis.md`
"Nested let values")を入れた結果、idris2-lspのdead offerは5,474 → 1,757、
実reuse(`con ... reuse=`)は7,811 → 12,189。残り:

- 本体側が一部のパスでしかclaimしない場合、本体側が優先されるので、値側でより多くの
  パスがclaimできてもそちらは見ない(本体がゼロclaimのときだけ値を探索する)。
- 内側のofferが同名conをすべて先にclaimしてしまうケース(約274箇所、bottom-up順の
  帰結)は未対応。
- 末尾`con ... reuse=`をDualABIがretpackに変えるクラスA(値を返す関数側)は別問題で未着手。
- 残ったdead offer 1,757件の内訳(値が呼び出しやクロージャで同名conが見えない等)は
  未分類。

## reuse: DualABI後の再確認(`noreuserecheck`)の残り (2026-10-08)

**状態: 調査済み・低優先(着手しない)。** 残りは合わせて100箇所未満(27 + 最大69)で、
効果が小さい。見直すのは、上の節と同じく実測で不足が見えたとき。

`Reuse.recheckReuse`(`rc2/doc/reuse-analysis.md` "Re-checking dead offers after
DualABI")で、idris2-lspの「同名の未claim `con`が隣にあるdead offer」は359 → 73、
`con ... reuse=`は+324。残り:

- `LateInline`が`Reuse`の後で差し込んだループ内のcon(約27箇所): `RLoop`は葉として扱うので
  claimできない。ループ内で別のofferを立て直すか、ループ化の前にReuseを走らせ直す必要がある。
- 「`Reuse`が走った時点ではconがまだ無かった」箇所(最大69箇所)は未対応。
- 監査の訂正: クラスAの真の数は1,056(1,542ではない)。旧クラスEはスクリプトの
  アーティファクトで実在しない。クラスDは359(うち332が本件の履歴)。

## ユーザ向けマニュアルの整備
```
doc/manual/
  00.getting-started.md
    - changes to upstream.
    - limitations.
  01.how-to-use-compiler.md
  02.directives.md
  03.C-struct.md
  04.two-different-type-of-FFI.md
```



## TagSoupの実装
もっとモダンなスクレイピングツールがあればいいのだが。HTML相手に正規表現では大げさ過ぎる。

## TTCの`foreignImpl`の指数的な肥大(upstream Idris2の不具合)
rc2baseは`%foreign_impl`を33件使っている(`System/Concurrency/RC2`、`Data/Buffer/RC2`、`Data/Double/RC2`)。
upstreamの`Core/Binary.idr`は、TTCを書くときその時点までに溜まった`foreignImpl`の全体を書き込み、読む側
(`updateForeignImpl`)は重複を除かずに先頭へ足す。そのためimportの段数に対して指数的に増え、
`Curl/Types.ttc`が137MB、`Curl/TextBuffer.ttc`が315MBになっている(`strings`で`prim__makeMutex`などが
各51,300回)。rc2base全体のコンパイルで`Fix foreign bindings`が58〜70秒、`TestWebAPI`のコンパイルは
ピーク約9GBになり、`libs/rc2base/tests/verify.sh`の`ulimit -v 12000000`の下でOOMになることがある。
最小の再現(`%foreign_impl`を持つ`M0`と、直前2つをimportする`M1`〜`M12`)では`M12.ttc`が6.2MBになる。

`updateForeignImpl`が既にある組を足さないようにする1箇所の修正で、再現は3.7KBのまま増えず、rc2baseを
作り直した`TestWebAPI`のコンパイルはピーク0.84GB、`Fix foreign bindings`は0.003秒になった(確認済み、
upstreamの`make test`は未実行)。パッチは`seagull-kamome/Idris2`の`fix_foreign_impl_oom`ブランチ向け。
upstreamに取り込まれたら`idris2-src`を更新して自作idris2を作り直し、rc2baseを再インストールする。
`namedirectives`/`cgdirectives`の読み書きにも同じ構造がありそうだが未調査。

## System.Posix / System.Linux の残り
`Time`・`Stat`・`Path`・`Fcntl`・`Poll`・`Select`・`Pwd`・`Glob`・`Syslog`・`Process`の拡張・`Signal`の集合とマスク・
`sigtimedwait`・`sigsuspend`・`sigqueue`・`Dl`・`System.Linux.{Pipe,Timerfd,Signalfd,Inotify,Clock,Dl}`は入った。残り:
- シグナル: `sigaction`のハンドラはIdrisの関数を渡せないので束縛しない(`signalfd`/`sigwait`で代替)。
  `sigsuspend`を起こすにはハンドラ付きのシグナルが要り、Idrisでは書けないので、実行テストは無い
  (コンパイルまでの確認)。
- `Pwd`: スレッド安全な`getpwnam_r`系は束縛していない(静的領域をすぐレコードにコピーする)。
  `Glob`: `GLOB_BRACE`/`GLOB_TILDE`(GNU拡張)と`glob_t`のオフセット系は無い。
- `dlsym`で得たアドレスの呼び出しは、`CExpr`で関数ポインタ型にキャストして書く(`System.Posix.Dl`の冒頭と
  `TestLinux`の例)。型付きの呼び出しヘルパを用意するかは別の判断。
- `CExpr`の文式`({ ...; })`はGNU拡張で、`rc2base`の8ファイル13か所で使っている(`Termios`の`getWinSize`/`setWinSize`、
  `Epoll`、`Select`の`FD_ZERO`/`FD_SET`、`Glob`の`globfree`、`Stdio`、`Syslog`、`Linux.Process`、`HTTP.Server`)。
  gccは問題ない。clangも文式に対応しており、`TestPosixTermios`の生成Cをclang 21で`-Werror`つきでコンパイルできることは確認した
  (rc2の既定の警告では出ない)。問題が残る場面:
  - `-pedantic`では`-Wgnu-statement-expression`の警告が出る(生成Cに他の`-pedantic`の警告も多く、今は使っていない)。
  - ファイルスコープの初期化子には書けない(`%inline`の`CExpr`をCAFの静的初期化子に展開するとCのエラーになる)。
  - MSVCなど文式のない処理系では通らない(今のrc2はそもそもPOSIX前提)。
  対策の案: 文式が必要な箇所は、`rc2base`の`support/c`に`static inline`の小さなヘルパ関数として置き、`CExpr`からは
  その関数を呼ぶだけにする(文式を使わず、型も引数に出る)。ほかの処理系に対応する必要が出た時に着手する。

## AI Agent作成用のライブラリを整備

## termui(INK風のTUIライブラリ)の残り

実装済みの範囲と制限は`libs/termui/doc/design.md`。未着手:

- OSのクリップボードを読むこと(OSC 52の`?`問い合わせ。端末が応答する。多くの端末は既定で禁止)。
- レイアウト: 絵文字のZWJ列と異体字セレクタ(端末が幅を変えるので合成できない)。
- コード規約: Loop/Frame/Programの、1か所でしか使わないトップレベル関数は`where`に入れた。
  Programの`draw`(約50行)と`currentView`も1か所でしか使わないが、大きいので残している。




### termui: 型で安全にできる箇所(調査 2026-10-19)

ウィジェット・`Style`・`Input`・`Node`は`%default total`。全域でないのは`Layout`・`Frame`・
`Loop`・`Program`・`Output`・`Terminal`(`covering`)。`believe_me`は無く、`assert_smaller`は
`Input.idr`の`splitSemi`の1箇所だけだった(なくした)。上から順に片付ける。

- 「燃料」で止めている再帰: `Layout`の`shrinkAll`・`flex`の`go`。
  `TextArea.wrapRows`、`Layout`の`charChunks`・`wordChunks`、`Input`の`loop`は、行頭で先読みして長さを決め、残りは
  先頭から1文字ずつ読み飛ばす構造再帰に書き直して燃料をなくした(旧版と結果が同じことを乱数で確かめた)。
  `Input`の`loop`は、`Step`が残りのリストでなく食ったバイト数を返すようにして同じ形にし、`splitSemi`の
  `assert_smaller`もなくした。これで`TermUI`の中に`assert_smaller`は無い。
  `shrinkAll`と`flex`の`go`は、リストを歩くのではなく不動点まで繰り返す。各ラウンドで少なくとも1項目が
  固定されるので`length + 1`回で足りるが、それを型で示すには「重みが0の項目に`distribute`は0を配る」
  という性質の証明が要り、費用に見合わない。燃料のまま残す。
- `TextArea.Model`の`line`/`count`(行数をO(1)にするための`above`/`below`の長さの複製)。
  `line = length above`と`count = line + 1 + length below`を型に載せられるが、`setItems`のような
  更新ごとに証明の更新が要り、費用が大きい。
- `MenuBar`の`active`/`cursor`、`Select`の`selected < length items`・`top ≤ selected`。
  今は飽和算(`min`/`minus`)で範囲外にならない。守る価値は将来の編集で壊さないこと。
- `keyed`は`Focusable`でないノードに付けても何もしない。`Focusable`だけの型を別に作れば型で防げるが、
  `keyed "name" (T.field ...)`の書き方が変わる。
- 勧めない: `Frame`の座標を`Fin w × Fin h`にすること(描画の内側のループが重くなる)。
- 座標と寸法は`Len`(`Int32`、`TermUI.Len`)にした。残り:
  - `TextArea`は内部の`cells`・`rows`・`top`・`left`などが`Nat`のままで、公開の入口(`empty`・`resize`・
    `fromString`・`keyMsg`・`view`)で`cast`している。行番号や文字の添字と画面の寸法が混ざっていて、
    素直には置き換わらない。`cells`・`rows`・`top`を`Len`にし、添字は`Nat`のまま分ける。
  - `TabStrip`(`Fin`の`active`)と`Splitter`(`Fin (S span)`の`offset`)は、`Fin`が`Nat`なので、
    寸法の入口(`Click`・`Drag`・`size`・`withLimits`)で`cast`している。`Fin`を捨てて`Len`にするか、
    範囲を持つ型を別に作るかは未定。
  - `MenuBar`の列(`Click`・`titleLeft`)は`Len`だが、`active`と`cursor`は添字なので`Nat`のまま。

## `Network.Async.HTTP.Static`/`CGI`/`Proxy`

- `static`は`Range`・`If-Modified-Since`・`Last-Modified`に答えず、ファイルを
  `chunkBytes`ずつ読むが、本体はメモリに全部置く(`maxFileBytes`で打ち切る)。`Response`の本体が`Buffer`なので、大きなファイルを流すには
  `Network.Async.HTTP.Server`側に本体を流す応答の型が要る。
- `cgi`は出力を全部集めてから応答する(`nph-`も流し出力も無い)。
- `proxy`は上流ごとに接続を張り直し(プール無し)、応答を全部集めてから返す。WebSocketの
  `Upgrade`、`Expect: 100-continue`(捨てる)、`X-Forwarded-For`(クライアントのアドレスを`Request`が持たず、
  持てば付けられる)、
  ホスト名の上流(`Network.Async.connect`がIPv4のみ)は未対応。
- `static`は`stat`と`open`の間の差し替えとシンボリックリンクの先を防がない(`O_NOFOLLOW`と
  `openat2(RESOLVE_BENEATH)`なら防げるが、`System.Posix`にまだ無い)。
- `cgi`は標準出力がEOFになるまで読むので、リーダーが終わっても孫が標準出力を握っていれば
  `timeoutMs`まで待って504になる(`timeoutMs = 0`なら待ち続け、出力が続けば`maxOutputBytes`で502)。その後でグループごと止める。
  リーダーが終わった時点でグループを止める手もあるが、子が出力を続けるCGIを切ることになる。
- `cgi`のpidfdが使えない環境(Linux 5.3未満)の待ち方は、先に`waitpid`で回収してから`kill(-pid)`する。
  グループが空でpid番号が再利用されていれば誤って別のグループへ送る窓が、理屈の上ではある
  (`waitid(WNOWAIT)`が`System.Posix`にあれば塞げる)。pidfdの経路は`kill`を先にしている。
- `cgi`は`SIGKILL`を受けても止まらない子(D状態)を専用のスレッドで回収する。回収を待つ接続が
  あるわけではないが、そのスレッドは子が戻るまで残る。

## HTTPクライアントの一本化

`Network.HTTP.Client.Curl.Async`(`libs/rc2base/doc/async-http-client.md`)ができたので、
自前のソケットでHTTPを話している2か所を載せ替える。

- `Network.Async.HTTP.Stream`: `streamPost`をこの上に載せる。https、名前解決、IPv6が使えるようになる。
  chunkのデコーダは不要になる(行分割とイベントのパーサは残る)。
- `Network.Async.HTTP.Proxy`の私用クライアント: 転送の厳格な検査(`Transfer-Encoding`の拒否、
  先頭行と`Content-Length`の検査、リダイレクトを追わない)を保ったまま載せ替えられるかを先に確かめる。
