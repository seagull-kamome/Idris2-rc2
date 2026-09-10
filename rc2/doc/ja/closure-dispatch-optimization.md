# クロージャディスパッチの高速経路(`rc2/support/rc2/runtime.c`)

(原文: `doc/closure-dispatch-optimization.md`。内容が乖離した場合は原文を正とする。)

`idris2rc2_applyClosure` における小さなランタイム限定の最適化の
実装ノート -- これは rc2 の非末尾呼び出しクロージャ適用エントリ
ポイントで、汎用の高階コード(`map`/`Foldable`/インタフェース辞書
メソッドディスパッチ)と、共有された `Delay` クロージャを繰り返し
再評価する `Force` 自身が使う。他のすべての `rc2/doc/*.md` 姉妹
ドキュメントと違い、これはコンパイラパスにも `RCExp` IR 形状にも
一切触れない -- 変更はすべての rc2 コンパイル済みプログラムに
リンクされる手書きの C ランタイムライブラリ
`rc2/support/rc2/runtime.c` に完全に閉じている。将来のセッション
(あるいは将来の自分)が安全性の論理を再導出せずに取り戻せるよう
書かれている。この最適化の*誤った*バージョンを述べる(下記
"なぜ `idris2rc2_tailcallApplyClosure` は意図的に手つかずにされたか"
を参照)のは簡単で、深い末尾再帰プログラムがクラッシュするまでは
正しく見えてしまうからである。

## 問題

rc2 のすべてのクロージャ適用は、最終的に 2 つのエントリポイントの
どちらかを通る。選択は `Compiler.RC2.Emit` の `RApp` に対する
`emitRC` ケース(`rc2/src/Compiler/RC2/Emit.idr:1060-1065`)が行う:

```idris
emitRC (RApp fc _ closure arg) tailPosition = do
   closureStr <- rcVarToBoxedC closure
   argStr <- rcVarToBoxedC arg
   pure $ (case tailPosition of
       NotInTailPosition => "idris2rc2_applyClosure"
       InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"
```

`idris2rc2_tailcallApplyClosure`(`runtime.c:301-323`)はクロージャ
を引数 1 個分だけ拡張する。クロージャが一意に所有されているとき、
これは単なるフィールド書き込みである。非一意(共有、refcount > 1
-- 例えば `map` が全リスト要素で再利用する `addN n` のような部分
適用や、`Force` が forced されるたびに同じ `Delay` 箇所に対して
再適用するクロージャ)のときは、代わりに `idris2rc2_mkClosure`
経由で*新しい* `IDRIS2RC2_Closure` を割り当て、既に埋まった各
引数をそこへ `idris2rc2_dup` し、元を drop しなければならない --
他の所有者(`map` の呼び出し側、まだ生きている `Delay` サンク)が
元のクロージャへの参照をその古いアリティで保持し続けており、その
まま見え続けなければならないからである。

`idris2rc2_applyClosure`(`runtime.c:325-342`、この変更前)は単純に
以下だった:

```c
IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *c, IDRIS2RC2_Value *arg) {
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(c, arg));
}
```

-- つまり `idris2rc2_tailcallApplyClosure` が返すものを常に即座に
トランポリン(ディスパッチ)する。クロージャがまだ飽和していない
ときはこれで良い(拡張されたクロージャは、*後の*適用が埋め続けら
れるよう本当に存在する必要がある)が、`arg` がクロージャの
**最後の**引数のとき、非一意ブランチが構築した新鮮に
`mkClosure` されたオブジェクトはただ 1 つの目的のために使われ --
`idris2rc2_trampoline` がそれを即座にディスパッチする -- そして
その場で再び取り壊される。最後の引数を受け取る共有クロージャに
とって、割り当て-コピー-ディスパッチ-取り壊しの往復全体が純粋な
オーバーヘッドだった: この 1 回の呼び出しの外では、その拡張された
クロージャオブジェクトを誰も観測しない。

## 修正: `idris2rc2_dispatchWithExtra` + 高速経路条件

新しいヘルパ `idris2rc2_dispatchWithExtra`(`runtime.c:169-277`)は、
クロージャの既に埋まった引数を dup し、`arg` を最後に置いて、対象の
`IDRIS2RC2_FUNn` 関数ポインタを直接呼ぶ。型付きの `1..20` 範囲の
すべてのアリティに対して行う(飽和済みクロージャに対して
`idris2rc2_dispatchClosure`、`runtime.c:90-157` が既に switch する
のと同じ範囲)。代表的なケース(20 個中の 1、2、3; 残りは
`idris2rc2_dup` 呼び出しを増やしてパターンを延長するだけ):

```c
static inline IDRIS2RC2_Value *idris2rc2_dispatchWithExtra(IDRIS2RC2_Closure *c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Value **const xs = c->args;
  switch (c->arity) {
  case 1:
    return (*(IDRIS2RC2_FUN1)c->fn)(arg);
  case 2:
    return (*(IDRIS2RC2_FUN2)c->fn)(idris2rc2_dup(xs[0]), arg);
  case 3:
    return (*(IDRIS2RC2_FUN3)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), arg);
  ...
  default:
    // Caller (idris2rc2_applyClosure) only reaches here for
    // 1 <= c->arity <= 20; the generic FUNSTAR arity is deliberately
    // out of scope for this fast path (falls through to the ordinary
    // mkClosure-based path instead).
    IDRIS2RC2_VERIFY(false, "idris2rc2_dispatchWithExtra: impossible arity %d", (int)c->arity);
    return NULL;
  }
}
```

`idris2rc2_applyClosure` 自身は今、古い経路にフォールバックする前
に、このショートカットが適用できるか検査する:

```c
IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *_c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;
  if (!idris2rc2_isUnique(c) && c->arity - c->filled == 1 &&
      c->arity >= 1 && c->arity <= 20) {
    IDRIS2RC2_Value *result = idris2rc2_dispatchWithExtra(c, arg);
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return idris2rc2_trampoline(result);
  }
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(_c, arg));
}
```

3 部構成の条件は、古い経路が終わった直後にクロージャについて成り立
つであろうことを正確に反映する:

- `!idris2rc2_isUnique(c)` -- 一意ケースは既に最適
  (`idris2rc2_tailcallApplyClosure` での単なるフィールド書き込み);
  この高速経路が狙うのは、非一意で `mkClosure` が本来発火する
  ケースだけである。
- `c->arity - c->filled == 1` -- `arg` が*最後の*引数、つまり拡張
  されたクロージャは、続く常在のトランポリン呼び出しによって即座
  に無条件でディスパッチされるだろう。引数が 2 個以上残っている
  場合、拡張された(まだ未飽和の)クロージャは将来の適用のために
  実際に保持されなければならないので、通常経路が使われる。
- `c->arity >= 1 && c->arity <= 20` -- `idris2rc2_dispatchWithExtra`
  が実装する型付き `FUNn` 範囲に制限する。下記 "スコープ" を参照。

条件が成立すると、元のクロージャの引数は対象の関数呼び出しへ直接
dup され(`idris2rc2_tailcallApplyClosure` の非一意ブランチが自身
の `mkClosure` した置換にコピーしたであろうものを正確に反映する)、
元のクロージャは drop され(変更されていなかったので、これは
トランポリン自身の無条件デクリメントイディオムではなく通常の
チェック付き drop である)、結果はいつも通りトランポリンされる。
この適用のために `IDRIS2RC2_Closure` が割り当てられることは一切
ない。

## なぜ `idris2rc2_tailcallApplyClosure` は意図的に手つかずにされたか

これはこの変更で最も正しく行う価値のある部分であり、類推で最も
誤りやすい部分である: 同じ「これが最後の引数なら `mkClosure` を
飛ばす」ショートカットが `idris2rc2_tailcallApplyClosure` 自身の
内部にも等しく適用できそうに見えるかもしれない。適用してはなら
ない。

`idris2rc2_tailcallApplyClosure` は、真に末尾位置のクロージャ適用
で生成コードから直接 -- `idris2rc2_applyClosure` を通さずに --
呼ばれる。まさに上で引用した `Compiler.RC2.RC2.Emit` の `RApp`
ケースの `InTailPosition` アーム(`Emit.idr:1064-1065`)である。
その場合のために、常に `idris2rc2_applyClosure` を呼ぶのではなく
*別の*エントリポイントが存在する理由そのものは、末尾位置の適用
がその場でディスパッチするのではなく、まだボックス化された
**未ディスパッチの**飽和クロージャを C 呼び出しチェーンの上へ
返さなければならないからである。実際のディスパッチは後で、スタック
の上方の別の有界な `idris2rc2_trampoline` `while` ループ
(`runtime.c:279-299`)で起きる -- このコードベースが深い末尾
再帰 Idris2 プログラムに C スタックを無制限に成長させないため
全体で依存する標準的なトランポリン技法である(姉妹機構は
`rc2/doc/loop-conversion.md` 自身の "Tail-call -> `goto`" セクション
を参照 -- *自己*または*相互*末尾再帰呼び出しはコンパイル時に
フラットな `goto` に変換される; 任意の静的に不明なクロージャを
通した末尾呼び出しは代わりに実行時にこの同じトランポリン規律で
跳ね返される。これこそ `idris2rc2_tailcallApplyClosure` の
「未ディスパッチで返す」契約が支えるために存在するものである)。

もし高速経路ディスパッチが `idris2rc2_applyClosure` だけでなく
`idris2rc2_tailcallApplyClosure` 自身の内部に追加されたら、
非一意/最終引数ブランチに到達する末尾位置クロージャ適用は、
`idris2rc2_tailcallApplyClosure` 自身のまだアクティブな C スタック
フレームの*内部から*、`idris2rc2_dispatchWithExtra` を同期的に
呼ぶことになる。対象関数自身が再び `idris2rc2_tailcallApplyClosure`
に着地する別のクロージャ適用へ末尾呼び出しすると -- まさに
自己参照的な(結び目状の)クロージャが生む形状(下記
`Test68ClosureFastPathStackSafety` を参照)-- これは本来フラットで
反復的なトランポリンの跳ね返りであるべきものを、真の無制限に
成長する C 再帰に変え、共有/非一意クロージャを中心に組まれた
あらゆる深い末尾再帰プログラムにスタックオーバーフローのリスクを
静かに再導入する。

`idris2rc2_applyClosure` をこの方法で最適化して安全なのは、まさに
*それが*どのブランチが走ろうと既に自身の結果を無条件で即座に
トランポリンするからである -- それはこの変更前から既に真だった。
その内部で割り当てを短絡させることは、最終ディスパッチにどう
*到達するか*を変えるだけで、それが*起きるかどうか*や*いつ*起きる
かは変えない: `idris2rc2_applyClosure` の呼び出し側は、どちらの
道でも既に完全にディスパッチされた結果を同期的に受け取ることに
なっていた。ディスパッチのタイミングについて観測可能な変化は何も
ない; 除かれるのは一時的な割り当てだけである。

## 遅延性: 乱すべきメモ化状態はない

`Force t` は `Delay e` 自身のクロージャに対する単なる
`idris2rc2_applyClosure` 呼び出しにコンパイルされる(生成 C で直接
確認済み: 二度 force される値は、間に何もキャッシュしない 2 つの
独立した `idris2rc2_applyClosure(var_0, NULL)` 呼び出しにコンパイル
される)-- 完全な導出は `TODO.md` の既存セクション
"Semantics: `Lazy`/`Force` defers evaluation but doesn't memoize"
を参照。`Force` は既に毎回無条件で即座にディスパッチし、コード
ベースのどこにも「飽和したが未ディスパッチのクロージャを後の別の
再利用のために残す」状態がないので、この最適化がここで乱すものは
何もなかった: 高速経路はその即座のディスパッチにどう*到達するか*
(割り当てを飛ばす)を変えるだけで、再 force が再計算するか*どうか*
は変えない(以前と全く同じく、今も再計算する)。

## スコープ: アリティ 1..20 のみ

`idris2rc2_dispatchWithExtra` は型付き `FUNn` 範囲のみを実装し、
`idris2rc2_dispatchClosure` 自身の型付き switch ケースに一致する。
アリティが 20 を超えるクロージャは代わりに汎用の配列ベース
`IDRIS2RC2_FUNSTAR` 呼び出し規約を使い(`idris2rc2_dispatchClosure`
自身の `default:` ケース)、`idris2rc2_applyClosure` の高速経路条件
(`c->arity <= 20`)から除外され、元の
`idris2rc2_tailcallApplyClosure` からトランポリンへの経路に無変更
で落ちる。これはこのラウンドのスコープにおける意図的な既知の
ギャップであり、見落としではない -- 除外の理由と拡張に必要なものは
`TODO.md` の "Performance: closure-dispatch fast path doesn't cover
arity > 20 (`FUNSTAR`)" エントリを参照。

## 参照テスト

- **`Test66ClosureFastPath` §1**(旧 `Test66ClosureFastPathMap`):
  2000 要素リストに対する `map (addN n) xs` -- `addN n` は部分適用
  (アリティ 2、埋まり 1)で `map` が全要素で再利用するので、
  最後の要素の場合を除いてすべての適用で非一意である。
  (現在は除去された開発時の計測により、)高速経路が要素ごとに
  ちょうど 1 回発火することを確認済み。
- **`Test66ClosureFastPath` §2**
  (旧 `Test67ClosureFastPathDictDispatch`): 手書き関数ではなく本物
  のインタフェース辞書由来の同じ形状 -- `map (k +) xs`、ここで
  `(k +)` は実行時辞書から取り出され捕捉された定数に部分適用された
  `Num` 自身の `(+)` メソッド。同じように要素ごとに 1 回発火する
  ことを確認済み。
- **`Test68ClosureFastPathStackSafety`**
  (`rc2/tests/Test68ClosureFastPathStackSafety/`): 上記安全性論理の
  ための専用回帰ガード -- 格納したクロージャを読み返して
  **末尾位置**で 10,000,000 回再適用する、自己参照的な
  (「結び目状の」)`IORef (Int -> Int)`。それらの適用のいずれも
  本当に非一意である(`IORef` 自身が毎反復クロージャへの生きた参照
  を保持する)ので、これはまさに、高速経路が
  `idris2rc2_applyClosure` ではなく
  `idris2rc2_tailcallApplyClosure` に追加されていたら無制限の C
  再帰に変わっていた形状である。同じ開発時計測により、高速経路
  ヒットを **0** 回記録すること(ここでのすべての適用が手つかずの
  `idris2rc2_tailcallApplyClosure` 経路を通ることを証明)を確認し、
  スタックオーバーフローなしで約 2.3 秒で完了することを確認済み。

これが着地した時点のフル `verify.sh` 実行: 87 passed, 0 known,
0 failed、valgrind クリーン。
