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


## `believe_me`された`Lazy`/`Inf`値を`force`する安全性が未確認

`idris2rc2_force`は、渡された値がセル(`IDRIS2RC2_TAG_LAZY`)でなければそのまま
返す(`rc2/doc/lazy-memoization.md`「`Force`」節)。`Delay`を経由せずに
`believe_me`で作られた`Lazy`/`Inf`値や、`Lazy`/`Inf`に触れる
`%foreign`宣言がこの経路を通るはずだが、upstreamの`base`/`contrib`に
実在するそうした値のすべてがこの扱いで安全かどうかは未調査のまま。

## `Lazy`/`Inf` のメモ化後: force した値への無駄な reuse 解析を省く

`rc2/doc/lazy-memoization.md`で実装した`Lazy`/`Inf`のメモ化により、force
した値はセルが生きている間ずっとセルと共有され、一意にならないので、その場
での再利用(reuse)は実行時に外れる。force がセルの最後の使用で、直後に
セルが解放される場合だけは一意に戻り、再利用できる。それ以外(force の後も
セルが生きている)の値に対する reuse 解析(`reuseOffer`/`releaseReuse` の挿入)
はコンパイル時間と生成コードの無駄なので、そうした値には reuse を試みない
ようにしたい。残る `reuseOffer` の数を数えて効果を確かめる。

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

## 他の`Lazy`引数関数にもupstreamのインライン展開が及ぶかは未調査
`&&`/`||`は`Lazy Bool`の短絡評価のために`Delay`に依存しているが、upstream
自身の`%inline`プラグマとモジュールコンパイル時の`compileAndInlineAll`が、
rc2が`NamedCExp`を受け取るより前に`&&`/`||`の呼び出しを展開してしまうため、
`Delay`/`Force`のノード自体がrc2側に渡ってこないと判明した(rc2側の対応は
不要)。他の`Lazy`引数を取る関数についても同様のupstream最適化が及ぶかは
未調査のまま。

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

### 計測(2026-09-27)
同じ生成Cを複数のランタイムにリンクして比較した(3回の最小値)。

| ベンチ | atomic(現行) | 全て非atomic | グローバルフラグ+union |
|---|---|---|---|
| idris2-missing-containers | 8.06s | 6.20s (-23%) | 6.68s (-17%) |
| `sort` 1M要素 | 3.17s | 2.37s (-25%) | 2.44s (-23%) |
| クロージャ1M個×20回 | 3.67s | 2.61s (-29%) | 2.72s (-26%) |
| map/filter 300k要素×50回 | 7.31s | 6.70s (-8%) | 6.71s (-8%) |

- 出力はどれも一致。refcountを多用する処理はほぼ一律25〜30%速くなる。
- オブジェクト毎の共有フラグは実用上設定しきれないので採らず、プロセス全体で
  一度だけ立てる「マルチスレッド」フラグで切り替える。
- refCountを`_Atomic`のままrelaxedで読み書きした試作は効果が半分しか出なかった。
  普通の`uint16_t`とのunionにして非atomic側は全てそちらを通すと大きく改善する。
- 実装済み(2026-09-27): プロセス全体のフラグで切り替える方式。`rc2/doc/hybrid-refcount.md`。
  missing-containersで-16%、sortで-23%。
- 残り: 逃げない事が判っている変数を非atomic版で固定するエスケープ解析。上限は
  missing-containersで8ポイント(全て非atomicとの差)。関数内で閉じた解析で固定
  できるのはidris2-lspで297,911箇所中57箇所しかなく無意味(計測は
  hybrid-refcount.md)。やるなら関数をまたいでスレッドへ逃げうる値を追う
  全体解析と、引数がスレッドに閉じている呼び出し元向けの関数の複製が要る。
- 関数の引数を通して連鎖させる粗い全体解析(複製なし)も見積もった。idris2-lspで5.3%、
  missing-containersで該当箇所を非atomicに固定しても6.48s→6.37s(-1.7%)で、全て
  非atomic(5.95s)との差の2割しか埋まらない。打ち切り。

## foo(%1, %2)形式のFFI定義
%foreignの自由度が上がればラッパを書く手間が減らせる。RC2専用かつC関数名が%で始まっている場合
といった条件なら問題なさそう。%+数字を展開する時には周囲にカッコをつける必要がある事に注意。

%foreignはCompiler.Commonのパーサで単純にカンマ区切りをしているらしく一筋縄では行かない。
jsのlambda:の時にはヘッダもライブラリも必要ないので全体を一つの式としてしまっているらしい。


## idris2-curlの取り込み
インストール時にlibcurlへの依存が無ければrc2baseへ取り込んでも問題ないはず。
よく使う機能はバンドルとしておきたい。あるいはpure idris2のhttp clientを実装すべき？

## promiseの実装

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

## Performance: box-then-unbox round trips left after native promotion

17 box-then-unbox round trips
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

Design and implementation (2026-09-25): `rc2/doc/struct-return.md`, on
by default (`--directive nostructreturn` turns it off). A
new DualABI stage returns a constructor with at most four fields as a
fixed `{tag, f0, ...}` struct (16 bytes, in registers, for one field); the Boxed wrapper
materialises the cell for every other caller. On idris2-lsp that covers
8,039 functions and 3,648 of the 4,959 call-then-`case` pairs; a
hand-written model of an `Either` chain runs 17-38% faster. `IO` is
already erased (`Core` returns a bare `Either`), reuse analysis already
limits today's cost to one malloc per chain, and tail calls between
eligible functions form no cycle, so they can become direct C calls.
Implemented through the call-site rewrite; `tests/BenchStructReturn.idr`
runs 30% faster and allocates half as often. Left: a run-time
measurement on a workload full of `Core`-style chains (idris2-lsp
cannot reach C generation, and that is not being worked on). Native
fields (2026-09-26, `Ret1:1=Int`) and constructors of up to four fields
(2026-09-26, idris2-missing-containers 15% faster) are done.

`MutualLoop`がまとめた関数(`{rc2_mutualLoop:N}`)も構造体返しの対象にした
(`--directive nomutualstruct`で切れる)。Loop後は群内の呼び出しが`goto`なので、残る
末尾呼び出しの環だけが除外される。idris2-lspでは13関数にworkerが付き、`con`ノードが
551減る。ループ主体の手製ベンチで約6%速い。

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


## Performance: `sort` against Chez -- stacked causes (measured 2026-09-26)

`Data.List.sort` of 1M pseudo-random `Int`s took 4.18s on rc2 and
1.23s on Chez. Cause 1 is fixed (`Compiler.RC2.DeadArgs`,
`rc2/doc/dead-args.md`), which brings `sort` to 3.21s, and the smaller
constructor cells of `rc2/doc/constructor-layout.md` to 3.12s. The rest remain.
Each cause was isolated by an experiment on copies of `Data.List`'s own
code:

| Variant | Time |
|---|---|
| `Data.List.sort` (before `DeadArgs`; 3.21s with it) | 4.18s |
| the same code copied into `Main` (B) | 3.21s |
| B plus one unused passthrough argument on `splitRec` | 4.19s |
| B with `order x y` replaced by `compare x y` (specialised) | 2.62s |
| B specialised to `x < y` | 2.03s |
| `x < y` version, non-atomic `dup`/`drop` + mimalloc | 0.99s |

1. **Fixed: an unused argument kept the input list alive** (~1.0s).
   The frontend's extra `where` arguments (`KNOWN-BUGS.md`) held the
   list's head through `splitRec`'s loop, defeating cell reuse; see
   `rc2/doc/dead-args.md`.
2. **Fixed: the comparator is never specialised.** SpecClosure now
   follows a closure forwarded from `sortBy` to `mergeBy`: `sort` 1.49s
   to 1.11s, below Chez's 1.23s
   (`rc2/doc/speculative-closure-specialization.md`, "Transitive
   specialisation").
3. **Fixed: atomic reference counts.** Plain until the program goes
   multi-threaded: `sort` 3.17s to 2.45s (`rc2/doc/hybrid-refcount.md`).
4. **glibc malloc** (-33% with mimalloc). See "a small-object
   allocator in the runtime" below.
5. **Fixed: boxed `Int`.** An `Int` within 62 bits is now immediate
   (`rc2/doc/immediate-ints.md`).

Re-measured after `DeadArgs` (3.21s):

| Variant | Time |
|---|---|
| as is | 3.21s |
| non-atomic `dup`/`drop` | 2.55s |
| mimalloc | 2.45s |
| both | 1.81s |

In the 1.81s run:
- **The TRMC'd `mergeBy` loop is 42%.** About two thirds of that is
  memory stalls:
  - loading the list cells' fields (37% of the loop);
  - touching the boxed `Int`s' refcounts to `dup` them for the
    comparator (30%).
- **The comparator call path is about 28%:** `applyClosureN`,
  `dispatchFn`, wrapper, worker, `trampoline`. There is no allocation;
  it costs about 25ns per comparison.
- **`split` is 8% and teardown 5%.**

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

idris2-lsp を`--timing 3`で`--cg rc2`ビルドしたログ(C生成は既知の
`FFI not found for ...unsafeVectorToList`で止まるので、その手前まで)
から。時間の大きい順に Early inline 6.66s、Late inline 4.71s、
RC annotate+Reuse+ConAltNative 3.03s、DualABI 3.02s、Inline 1.54s、
ConstFold 1.32s。

### 1. 計測を分ける(他の案の前提)

- **DualABI(3.03s)の大半は構造体返し。** 計測を分けた結果(2026-09-29):
  workers 0.11s、**struct return(`applyStructReturn`) 2.60s**、FFI worker
  table 0.05s、call-site rewrite 0.21s、FFI inline 0.07s。構造体返しの中は
  plan(`structReturnPlan`) **1.60s**、prune plan 0.35s、worker names 0.02s、
  layouts 0.14s、rewrite 0.44s。planは`settle`(合わない関数を除外して
  収束まで)の各周で`eligible`を一から計算し直し、その中の`shrink`/`reach`も
  周ごとに集合全体を`filter`して`length (SortedSet.toList ...)`で数え直す
  ので、周回数×定義数に比例すると見込まれる(コードを読んだ推定。周回数は
  未計測なので、まず数える)。変化した名前だけを次の周に回すワークリスト
  方式にすれば、1周目以降のコストは変化分に比例する。
  **済み(2026-09-29):** 周回数はsettle 2周、各周でshrink 7・reach 7、
  shapeFix 2と8だった。shrink/reachをワークリストに、shapeFixを「前の周で
  増えた名前の呼び出し元だけ再計算」にして、plan 1.61s→0.69s(出力不変)。
  残りはprune plan 0.35s、rewrite 0.44s。
- **「RC annotate + Reuse + ConAltNative」(3.03s)は3パスの合計。**
  定義ごとに3つを続けて回しているので、パスごとの合計時間を別々に
  出す(`logTime`を定義ごとに付けると件数が多すぎるので、各パスの
  時間を足し上げて最後に1行出す形)。
- **Early inline(6.68s)の内訳。** 計測を分けた結果(2026-09-29): ラウンド1
  2.25s、ラウンド2〜4 計2.23s、展開後の再畳み込み(`foldConstDef`、全定義)
  1.12s、PushCon 0.23s。
  **試して見送り(2026-09-29): 再畳み込みを展開された定義だけに限る。**
  1.11sが0.97sになっただけ(ラウンド1で8106件展開されるので、展開された
  定義が全体の大半)で、しかも出力が変わった(idris2-lspのIRダンプが約49万
  バイト増)。展開されなかった定義も、先行するPushCon・特殊化の後なので
  再畳み込みで良くなるものがある。
  **済み(2026-09-29): 呼び出しの表を1つにまとめて共有。** 定義ごとの呼び出し
  先の集合と出現リストを回数の表(`callCountsOf`)1つにし、`cyclicNames`と
  第1ラウンドの分析で共有した。出力は不変で、Early inline 6.66s→6.42s、
  Late inline 4.71s→4.43s。`cyclicNames`の残り約0.68sはほぼTarjan。
  **試して見送り: 第1ラウンドの処理順に、刈り込み前のTarjanの結果を流用。**
  6.06sまで縮んだが出力が変わった。`Carried.order`のコメントは処理順を
  「結果を変えない目安」としているが、実際には結果に効く。
- **C生成の時間が idris2-lsp では測れない。** 既知のエラーで止まる
  ため。C生成まで通る大きなプログラムを計測用に決めておく。

### 2. Early/Late inline: 収束しかけたラウンドの固定費

Late inline の各ラウンドは、展開件数が減っても時間があまり減らない:

| ラウンド | 前ラウンドの展開数 | 時間 | うち LI prune | LI analyse |
|---|---|---|---|---|
| 3 | 141 | 0.51s | 0.26s | 0.12s |
| 4 | 21 | 0.40s | 0.22s | 0.06s |
| 5 | 2 | 0.40s | 0.21s | 0.06s |
| 6 | 0 | 0.39s | 0.21s | 0.06s |

LI prune と LI analyse がプログラム全体を毎回見直しているため。
ラウンド6は前ラウンドの展開が0件でも、刈り込みで定義が減ったので回る
(`changed`は展開か刈り込みのどちらかで真。刈り込みで呼び出し元が
1つになる関数が出うるので、打ち切ってはいけない)。
Early inline も同じ形(ラウンド4で展開1件、0.42s)。案:

- **差分だけ見直す**: prune と analyse を、前ラウンドで展開した定義と
  その呼び出し元・呼び出し先に限る。展開数が数十件以下のラウンドの
  固定費(約0.3s)が減る。両パスで収束側のラウンドが計5〜6回あるので、
  最大で1.5s程度。
- **上限**: 展開数が一定以下になったら打ち切る(効果の小さい
  最後の数件を諦める)。性能への影響をベンチマークで確かめる必要がある。

### 3. 既知の落とし穴の点検

`code-style-Idris2.md`の「性能上の落とし穴」(`List`の`concat`/
`concatMap`、`union`の引数の向き、`where`で束縛した集合の再計算、
部分木の繰り返し走査)は、過去に LateInline・SpecClosure・DualABI・
RC.annotate・DeadVars で実際に数秒を失った。1の計測で重いと分かった
パスから順に、同じ形が残っていないかを点検する。

## テストの穴(監査 2026-09-29)

テストを72本から51本にまとめ(`rc2/tests/README.md`)、コンパイラの
パスと実行時の機能をテストの一覧と突き合わせた結果。大きいものから。

- **失敗すべきプログラムのテストが無い。** verify はコンパイルが通る
  プログラムしか試さない。rc2 が利用者向けのエラーにする経路
  (`%foreign`の戻り値が関数、`getField`の構造体やフィールドが見つからない、
  名前がリテラルでない`getField`など)が、エラーを出すことも、内部エラーに
  ならないことも確かめられていない。期待するエラー文をファイルに置き、
  コンパイラの出力と diff する形にする。
- **インクリメンタルコンパイル(`--inc rc2`)のテストが無い。** verify は
  全体コンパイルしか試さない。
- **大きな外部プログラムが verify に無い。** idris2-lsp は C の出力で既知の
  エラーで止まり、idris2-missing-containers は bench.sh でしか動かさない。
  少なくとも idris2-lsp の IR を lint にかける手順があると、スモーク
  テストに無い形を広く試せる。
- **専用のテストが無いパス。** `DeadVars`(死んだ let の消去)は他の
  テストで間接的に通るだけ。`MutualLoop`は Test110Loop の SelfTailLoop の
  中の間接的な循環1つだけ。
- **まとめたテストの注意。** Test113DeepRecursion は、まとめたことで
  `mod`がワーカー呼び出しになる、`mergeBy`の特殊化の展開が変わるなど、
  元のテストと IR が違う。100万段で C スタックが溢れないことは実行で
  確かめているが、元のテストと同じ形を狙いたい場合は分け直す。

## dup/dropの非効率改善
idris2rc2\_rt\_retainと idris2rc2\_rt\_releaseはdup/dropまとめる。必要無いのに関数を分割して複雑性を導入してはいけない。

# gen-env.shは今度こそ要らないはずなので削除
ドキュメントも修正

# rc2base/test/verify.shがni-shellを要求している
- rc2自身同様nix-shellは使わない。必要なパッケージは外側でロード済とみなす。
- 各テストに専用ディレクトリを用意し、テストコード、.expected、後処理スクリプトを
  テスト単位にまとめる


## 比較の入れ子の合成: `<`と`==`の対を`<=`へ(調査 2026-10-06)

`x <= y`を`compare x y /= GT`で書いた形は、Criterion Aのcallee-first展開
(`rc2/doc/inlining.md`)でcompareが展開されると、次の入れ子の比較になる。

```
cmp <Int [x, y]  then A  else  cmp ==Int [x, y]  then A  else B
```

これは`cmp <=Int [x, y] then A else B`と同じ意味。`>`と`==`の対なら`>=`。
比較演算子の`LTE`/`GTE`は`RCExp.idr`の`IsCmp`に既にあるが、入れ子を
まとめる処理は無い。

- idris2-lspのdump(2026-10-06)で、`else`の直後に`cmp ==`が来る組は42か所
  (比較の分岐は全体で551)。全体では小さい。利用者のプログラムで`compare`
  経由の`<=`/`>=`が多ければもっと出る。
- 実装するなら、dup/dropが入る前のRCExp(`ConstFold`の近く)に小さな変形を
  足す。条件は、外側と内側が同じ2引数・同じ型の比較であること、演算子の組が
  `{<, ==}`か`{>, ==}`であること、外側と内側のthen枝が構造的に等しいこと。
  dump上の`postDrop`はdup/drop挿入後の表現なので、そこでは扱いにくい。
- `Integer`/`String`の比較(`Nat`を含む)は`cmp`に融合するようにした(2026-10-07)。
  `tryFuseCompareOp`が`Types.boxedCmpEligible`(`Integer`と`String`)も通し、
  Boxedのオペランドのまま`int cmp_N = idris2rc2_lt_Integer_raw(a, b)`のような
  `_raw`ヘルパー(`idris2rc2_numeric.h`)で分岐する。オペランドは`ROp`と同じく
  `postDrop`で解放する。設計は`rc2/doc/native-type-inference.md`の
  "Comparisons over Boxed operands"。
  - idris2-lspのdump: `cmp`が551から1175へ(うち`Integer`/`String`が624)、
    `op <Integer`/`==String`等の`let`+`case`の組が632から8へ。`dup`は79113から
    79112、`drop`は80495から80467で、ほぼ変わらない(Boolの`let`はstage 1で既に
    `dup`/`drop`が付かなかった)。リンタの漏れ検査は異常0で、検査対象の定義数も
    同じ(17534)。
  - 実行時間は変わらなかった(`BenchBoxedCompare`、`Integer`の即値・ヒープと
    `String`の比較の分岐: 0.174秒が前後で同じ。gccが元の`mkBool`の往復を
    既に消していた)。効果はIRとCの見通しと、`mkBool`/`to_i64`の削減にとどまる。
  - 残る未融合: `case`の対象が比較の直接の結果ではなく、`let`で束縛された
    変数になっている形(`Eq Nat`の`==`をインライン展開した後など。lspで8組)。
    なぜその形になるのかは調べていない。
  - `compare x y /= GT`の形は、`compare_Ord_Integer`のworker内で`cmp <Integer`と
    `cmp ==Integer`の入れ子になる(`Ord Int`と同じ形)。lspでの呼び出しは24か所の
    ままで、展開されない理由(`delegatingThreshold`の20を超えるか)は測っていない。
    `<`と`==`の対を`<=`にまとめる変換(上)は`Integer`にも使える。
- 同じ結果を返す複数の`case`の枝(`0 -> 10; 1 -> 10; _ -> 10`)を1つにまとめる
  処理は、`ConstFold`/`Sink`/`DeadVars`/`DupMerge`/`Emit`/`RC`/`Reuse`の
  grepの範囲では見つからなかった(`DupMerge`はdup/dropの統合で別物)。
  入れるなら`ConstFold`の`case`の簡約の近くが候補だが、未調査。

## 借用推論(borrow inference): 計測して保留(2026-10-07)

`dup`/`drop`を減らすため、読むだけの引数を借用にする推論を検討した。

- annotate前(pre-RC IR)で推論する案は、rc2では位置が合わない。借用を決める
  事実(構築子の再利用`Reuse`、ループ変換`MutualLoop`/`Loop`、nativeになる
  引数`DualABI`、`LateInline`)の多くがannotateの後で決まるため、保守的に
  推測するしかなく、idris2-lspで借用にできた引数は5.9%、呼び出し側の`dup`の
  削減は0.6%だった。末尾呼び出しがループに変換されるかの予測は危険なので
  やらない。診断のコードは`tmp/BorrowMeasure_preannotate.idr`に退避。
- annotate後(最終IR)で数えると(`tools/rcexpr-lint --borrow-stats`)、
  idris2-lspで借用にできるBoxed引数は14.0%(6,802/48,336)。阻害要因は、格納
  13,836、ループでない末尾呼び出しの引数13,752、所有の位置への受け渡し8,930、
  返却1,517、再利用1,510、`apply`/FFI 1,356、ループで変わる引数633、複数の理由
  5,821。
- 効果は、呼び出し先の`drop`除去12,510と呼び出し側の`dup`除去3,521などに対し、
  呼び出し側の`drop`追加7,549(うち3,164は末尾呼び出しが末尾でなくなる分)で、
  静的な純減は3.2%(全`dup`/`drop` 284,067のうち9,321)。ループの中の重みでは
  追加の方が177多く、逆効果。所有の規約のwrapperが要る定義は2,111。
- 判断: 今の形では導入しない。再検討するなら、`callRep`だけのwrapper定義
  (690個、Boxed引数2,124)が「ループでない末尾呼び出し」で除外されている点
  (実行時にはtrampolineされないので規則が厳しすぎる可能性)と、`case`の
  フィールドの`dup`(4,342、うちループ内2,005)を借用で扱えるか(再利用と衝突
  しうる)から。

## dup/dropの押し込みの取りこぼし: 計測(2026-10-07)

`tools/rcexpr-lint --pushdown-stats`(最終IR、静的な箇所数)でidris2-lspを測った。
`dup`/`drop`操作は全体で290,924(dup 86,260、drop系 204,664)、ループ内は41.8%
(末尾再帰の関数全体がループ化されるため粗い指標)。種類どうしは重複する(Aの
フィールド系とDは同じdupを別の側から見ている)ので合算できない。

- E: 枝の先頭のdrop(すでに効いている押し込み)は46,566箇所、全dropの73.4%。
- A(対応済み、2026-10-08): caseの上のdupが一部の枝でdropに打ち消される形は12,271箇所(除去
  可能な操作19,274、6.6%)だった。担当は`RC.annotate`と見ていたが、`annotate`は使用箇所にしかdupを置かない。
  `case`の直前に`dup`/`drop`だけが並ぶ形(隣接、8,535箇所)の内訳は、caseのフィールドが
  6,161箇所(`Reuse.resolveAlt`の`dupOnSurvive`と`outerDrop`の形: 生き残るフィールドを
  全て親のdropの前にdupする)、フィールドでないものが2,374箇所(`LateInline`・`Loop`・
  `ConAltNative`が足すと見られるが、パスを切っての確認はしていない)。そこで最終IRに対する独立パス`Compiler.RC2.PushDown`(`DeadCode`の後、`DupMerge`
  の前、`--directive nopushdown`で切れる、`rc2/doc/pushdown.md`)にした: `case`の直前の
  `dup`/`drop`だけの連なりを全ての枝の先頭に移し、枝先頭のdropと正規形(dupを先、dropを後)で
  相殺する。`dup`を早める・`drop`を遅らせるのは安全で、`let`や`postDrop`付きの`cmp`は
  またがない。静的な操作数が増える場合は適用しない。先に見つけたリンタの数え間違いも直した:
  整数演算(`isReuseConsumingOp`)の`postDrop`は`Emit`が無視してdupが本物の参照になるので、
  Aでも消費扱いにした(Bは217箇所から72箇所になった。消えた145箇所は整数演算で、残りはcallRepだけ)。`idris2-lsp`(同一
  コンパイラで`nopushdown`と比較): `dup`行 78,483 -> 74,835、`drop`行 71,191 -> 64,999、
  IR行 670,479 -> 660,639、dup/drop操作 269,416 -> 255,574(-5.1%)、A 12,277箇所(19,255操作)
  -> 5,065箇所(5,057操作)、D 19,410箇所(29,584操作) -> 13,421箇所(20,827操作)、
  rcexpr-lint異常0件、PushDown段0.13秒。残りのAは`let`/`cmp`をまたぐもの(4,755箇所、多くは
  呼び出し結果を`case`する形)と、枝先頭より深い所で打ち消すもの。
- B(対応済み、2026-10-07): 同じ変数の`dup`と直後の`postDrop`の対は3,361箇所(6,722操作、
  2.3%)だった。`RC.annotate`が読み取りオペランドを消費扱いにして`dup v`を入れ、ノード
  自身の`postDrop=[v]`で戻していたため。`DupMerge.cancelRun`が、読むだけのノード(`op`・
  `extprim`・`cmp`・オペランドを消費しない呼び出し)の`postDrop`と相殺するようにした
  (`rc2/doc/reading-the-ir.md`の6節)。同じ`idris2-lsp`で3,361 -> 227箇所(callRep 80、
  op 147)。残りは、主に整数演算など`isReuseConsumingOp`の`op`(`postDrop`をEmitが無視し、
  `dup`が本物の参照渡しになる)と、別のオペランドを消費する呼び出しで、設計どおり
  (整数演算は後にリンタが消費扱いにしたので、今のBの数え方では対象外)。
  dup/drop操作は288,537 -> 281,497(-2.4%)、IRは688,874 -> 681,661行、`--timing 2`の
  コンパイル時間は56.5s -> 55.8s(DupMerge段は+0.4s程度)。リーク検査は異常0件のまま。
  `postDrop`を持たない`cmp`の対はリンタのBに数えられていない(scanBが`cmp`で止まる)が、
  同じ相殺の対象に入れてある。
- C0(対応済み、2026-10-07): `let v2 = v1; drop [v2]`の別名は3,166箇所(別名2,567)だった。
  再現できた形は、1か所からしか呼ばれない`where`関数(親の引数が変わらない引数として
  付く)を`LateInline`が取り込むときの別名`let f = actual`で、片方の枝が読まないと
  その枝にドロップだけが残る(Test79DupMergeの`readAll`)。`DupMerge.cancelDupDrop`で
  `drop [v1]`に置き換える(`v1`がboxedのときだけ。nativeなら別のboxになる)。
  3,166 -> 614箇所、別名は2,567 -> 15。残りは別名15と、別名ではない種類(nested let
  value 417、extprim 135など)。後者は今回の対象外。
- C1(全枝でdropされるだけのlet): 0件。C2(1枝だけで使うlet): 1,234箇所だが、
  大半は`Sink`が設計どおり動かさない種類で、怪しいのは3件。
- D: フィールドの`dup`の後に親の`drop`が19,616箇所(30,004操作、10.3%)あった。PushDown後は
  13,421箇所(20,827操作、8.1%、ループ内9,914操作)。うち「枝が新しいconを作る」5,027箇所
  (9,841操作)、「作らない」8,394箇所(10,986操作)。親が一意なら両方消せるが、実行時の
  一意性判定が要る。設計メモ(未実装):
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

## Bool: nativeにする段階計画(調査 2026-10-07)

`Bool`はすでに`Int8`のタグ付き即値(`mkBool = mkInt8`、`idris2rc2_memory.h:164`)で、
IR上では`B8 1`/`B8 0`。native(`Native Bits8`)になれる範囲はかなり広く、
`allPos`/`firstLessI`/`eqList`などはすでに`ret= Native Bits8`。残るのは、比較
プリミティブの結果、関数呼び出しの結果、`case`式の値。

返り値がnativeにならない条件(`DualABI.idr:114-168`の`tailValueReps`): 末尾に
比較プリミティブ(`opResultRep`が`Nothing`)か関数呼び出しが1つでもあると
`allJustSame`が失敗する。`Core.Name.(==_Eq_Name)`が`ret= Boxed`なのは末尾に
`call (==_Eq_Name)`と`call Namespace ==`があるため。

枝の先頭のdropが0/1のscrutineeを落とす4,008件の出どころ(idris2-lsp、代理指標):
関数呼び出しの結果1,319、パラメータ/フィールド/ループ引数855、比較プリミティブ628、
その他711、case式の値405、apply等90。

- 段階1(低リスク): 比較プリミティブの結果の`let`束縛を`alwaysUnboxed`と同等に
  扱い、`dup`/`drop`を省く。生成物は必ず`mkBool`の即値。対象628件。
  `alwaysUnboxedBoxedLocalsR`(`RC.idr:494-`)に判定を足す。
- 段階2(完了): 返り値の推論に、末尾が`B8`リテラル/native `Bits8`/他の同種関数への
  呼び出しである関数を`ret= Native Bits8`にする規則を足した(`boolReturnPlan`、
  関数をまたぐ最大不動点、末尾呼び出しの環は除外、`--directive noboolret`で切れる。
  `rc2/doc/dual-abi.md`の"Bool return")。比較プリミティブは前段で`case`の0/1リテラルに
  なっているので、単独の規則も`Integer`/`String`用のC側`int`版も要らなかった。
  idris2-lsp(同一コンパイラで`noboolret`と比較): `ret= Native Bits8` 362 -> 594、
  `ret= Boxed` 13,976 -> 13,831、枝の先頭のdrop 3,381 -> 2,633、`drop`行 81,195 ->
  80,495、DualABI 1.96s -> 2.19s、全体の差は誤差、rcexpr-lintは異常0件。未着手:
  `MutualLoop`が畳まなかった末尾呼び出しの環(Boxedのまま)。
- 段階3(完了、`--directive noboolcase`で切れる): 計測の結果、当初想定の「パラメータ
  /フィールドの生産側証拠の不動点」は不要だった。`B8`定数の`case`で直接分岐される
  `Bool`パラメータは、`paramEligibility`(`constAltsNativeType`)がすでに`Native Bits8`に
  しており、`B8`の`case`の枝先頭dropのうちパラメータは6件、ループ引数は1件(1,453件中)。
  なお旧い「855件」の代理指標は`0`/`1`の枝を種別なしで数えていたため、Nat/Int/3値以上の
  enumが混ざっていた(ダンプの定数に種別を付けて再分類した)。代わりに、型付きの定数を
  消費側の証拠として使う: `RConstCase`のaltが全て`alwaysUnboxed`型(`B8`/`Char`/`Int8`..)
  の定数なら、そのscrutineeは即値で`dup`/`drop`は不要(`Types.typedConstScrutinees`、
  `RC.definitionNatives`が`natives`に加える)。**`Bool`かどうかではなくunbox判断だけ**に
  使う(`Bits8`/enumは2..255もありうる; `case`・default枝は一切書き換えない)。`0`/`1`の
  リテラルではなく定数の型が証拠なので、`Int`/`Nat`の`case`(`I`/`BI`のalt)には効かない。
  DualABIの呼び出し側書き換えは、そのローカルを`postDrop`から外す
  (`stripImmediatePostDrop`)。ダンプは該当altを`u: 1 ->`と印字し(`Pretty.immediateMark`、
  rc2baseのパーサは`u:`を許す)、rcexpr-lintは同じ集合を再導出する(`Leak.idr`の
  `typedImmediateAlts`、フィクスチャ`typedcase.rcexpr`)。
  idris2-lsp(同一コンパイラ、`noboolcase`と比較): `drop`行 80,467 -> 78,871(-1,596)、
  `dup`行 79,112 -> 79,113、IR行 680,384 -> 678,789、枝先頭のdrop(定数altが全て
  always-unboxed型のscrutinee) 1,463 -> 526、RC annotate 2.66s -> 2.76s、DualABI
  2.20s -> 2.26s、全体は誤差(約55秒)、rcexpr-lintは異常0件。出どころ別の内訳(1,453件):
  フィールド508、`case`値の`let`253、`dup`エイリアス231、呼び出し結果204、その他181。
  **残り(約500件)はコンストラクタのフィールド**: `annotate`のフィールド`dup`と、
  `ConAltNative`がシャドウを作るときに再導出する所有権(`reannotateFieldOwnership`)が
  `natives`を見ないため、フィールドの`dup`/`drop`が残る。後続タスク: (a) alt境界で
  `RConCase`のフィールドにも型証拠(コンストラクタ名、またはフィールドの型)を与える、
  または(b) `ConAltNative`を`natives`対応にする。試作(全`dup`/`drop`/`postDrop`/
  `reuseOffer`リストから該当ローカルを後段で除去)では`drop`行が約71,000(-9,400)まで
  減ったが、rcexpr-lintに異常が出たので採用していない(試作は未採用)。
- 段階3b: コンストラクタフィールド(完了、`--directive noboolfield`で切れる。
  `noboolcase`でも切れる): `Reuse.resolveReuse`が分解したフィールドを親のdrop前に
  `dup`し`dupOnShared`/`dropOnUnique`に全て載せること、`ConAltNative.shadowOneField`が
  所有権をゼロから再導出して`drop`を足すことが、段階3の`natives`を見ていなかった。
  両者に`typedConstScrutinees`の集合(`RC2.immOf`)を渡し、型付き定数で分岐される
  フィールドを外した。`case`/default枝は触らない。`Emit`は各フィールドをalt入口で
  Cローカルへ取り出すので、親をdropした後も即値は有効。広い版(後段で該当ローカルの
  refcount操作を全て除去)でrcexpr-lintが出した異常の原因は、lintが「caseのフィールド
  は親の参照を借りている」とみなし、`drop [親]`後の読みをuse-after-freeとする点
  (ヒープのフィールドなら正しいが即値には誤り)。`Lint.idr`が`u:`のcaseのscrutinee
  を実質無限の参照数で種まきし、借りフィールドとして再束縛しないようにした
  (`typedcase.rcexpr`に親drop後の読みを追加、`u:`を外すと従来どおり検出)。
  idris2-lsp(同一コンパイラ、`noboolfield`と比較): `dup`行 79,113 -> 78,483、`drop`行
  78,871 -> 71,191(-7,680)、IR行 678,789 -> 670,479、枝先頭のdrop 526 -> 120
  (残りはフィールド13、パラメータ14、他は`let`束縛のBoxedな呼び出し結果など)、
  rcexpr-lint異常0件。調査済み(2026-10-08、再現せず): 狭い版の最初の2回のidris2-lsp実行で、1か所の
  `reuseOffer ... dupOnShared`のidが`v261316`でなく`v271316`と出力され(lintが
  over-consumeを報告)、その後は再現しなかった。コールド9回+ウォーム3回(この変更)と
  master 9回で、ダンプは各ツリー内で完全に一致した(`ulimit`の有無、作業ディレクトリ、
  2並列、環境変数のサイズを変えても)。`Reuse`・`ConAltNative`・`immOf`に順序の不定な
  コンテナやスレッドは無い。差がちょうど+10000の1箇所だけなので、連番のずれではなく
  実行環境側(共有の`install/idris2-lsp/build`への同時書き込み、古い・ビルド途中の
  `idris2-rc2`、入力の違い)を疑う。再発したら、実行直後の`idris2-rc2`の更新時刻とコミット、
  出力のmd5、同じディレクトリを使っていた他のプロセスの有無を残すこと。
- やらない: 消費側の0/1だけを根拠にパラメータを`Bool`と推論すること。

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
