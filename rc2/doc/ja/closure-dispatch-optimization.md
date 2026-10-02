# クロージャディスパッチの高速経路(`rc2/support/rc2/runtime.c`)

(原文: `doc/closure-dispatch-optimization.md`。内容が乖離した場合は原文を正とする。)

本書は、`idris2rc2_applyClosure` に加えた小さな最適化の実装メモである。
`idris2rc2_applyClosure` は、rc2 が末尾位置でないクロージャ適用に使う入口であり、
`map`・`Foldable`・インターフェース辞書のメソッド呼び出しといった、汎用の高階関数の
コードが利用する。`Force` が `Delay` のサンクを評価する処理は、別のランタイム関数を
通り、ここは通らない(後述の「遅延評価」を参照)。この最適化は、`rc2/doc/` にある
ほかの補足ドキュメントとは異なり、コンパイラのパスにも `RCExp` のIRの形にも一切
触れない。変更は、rc2 でコンパイルしたすべてのプログラムにリンクされる手書きの
C ランタイムライブラリ `rc2/support/rc2/runtime.c` に限られる。

この最適化は、誤った形で書いてしまいやすい。しかも、深い末尾再帰のプログラムが
クラッシュするまでは、正しく動いているように見える(後述の「`idris2rc2_tailcallApplyClosure`
を意図的に変更しなかった理由」を参照)。そこで本書は、将来の担当者(あるいは将来の
自分)が、安全性の根拠をゼロから導き直さなくて済むように書いている。

## 問題

rc2 のクロージャ適用は、最終的にすべて2つの入口のどちらかを通る。どちらを使うかは、
`Compiler.RC2.Emit` の `RApp` に対する `emitRC` のケース
(`rc2/src/Compiler/RC2/Emit.idr:1060-1065`)が決める。

```idris
emitRC (RApp fc _ closure arg) tailPosition = do
   closureStr <- rcVarToBoxedC closure
   argStr <- rcVarToBoxedC arg
   pure $ (case tailPosition of
       NotInTailPosition => "idris2rc2_applyClosure"
       InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"
```

`idris2rc2_tailcallApplyClosure`(`runtime.c:301-323`)は、クロージャに引数を1つ
追加して成長させる。クロージャの所有者が1つだけなら、これは単なるフィールドへの
書き込みである。所有者が複数(共有されていて参照カウントが 1 より大きい)なら、
そうはいかない。たとえば `addN n` のような部分適用を、`map` がリストのすべての
要素に使い回す場合である。この場合は、`idris2rc2_mkClosure` で*新しい*
`IDRIS2RC2_Closure` を割り当て、すでに埋まっている各引数を `idris2rc2_dup` して
そこにコピーし、元のクロージャをdropしなければならない。`map` の呼び出し元など、
ほかの所有者が元のクロージャを以前のアリティのまま参照しており、それが変わっては
困るからである。

この変更の前の `idris2rc2_applyClosure`(`runtime.c:325-342`)は、次のとおり単純
だった。

```c
IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *c, IDRIS2RC2_Value *arg) {
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(c, arg));
}
```

つまり、`idris2rc2_tailcallApplyClosure` が返したものを、常にすぐトランポリンで
ディスパッチしていた。クロージャがまだ飽和していない場合は、これで問題ない。成長した
クロージャは、*後の*適用でさらに引数を埋めるために、実際に存在していなければ
ならないからである。しかし `arg` がクロージャの**最後の**引数である場合、共有されて
いるクロージャに対する非ユニーク分岐が `mkClosure` で作った新しいオブジェクトは、
`idris2rc2_trampoline` が直ちにディスパッチするためだけに使われ、その場ですぐ解体
される。共有されたクロージャが最後の引数を受け取るとき、割り当て、コピー、
ディスパッチ、解体という往復は、すべて無駄だった。成長したクロージャのオブジェクトは、
この1回の呼び出しの外からは観測されないからである。

## 修正: `idris2rc2_dispatchWithExtra` と高速経路の条件

新しいヘルパー関数 `idris2rc2_dispatchWithExtra`(`runtime.c:169-277`)は、クロージャ
にすでに埋まっている引数をdupし、`arg` を最後の引数にして、対象の
`IDRIS2RC2_FUNn` の関数ポインタを直接呼び出す。対応するアリティは、型付きの
`1..20` の範囲全体である。これは、飽和済みのクロージャに対して
`idris2rc2_dispatchClosure`(`runtime.c:90-157`)がすでにswitchで分けている範囲と
同じである。以下は、20個のうち 1、2、3 の場合を示した代表例で、残りは
`idris2rc2_dup` の呼び出しを増やしながら同じパターンを延長したものである。

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

`idris2rc2_applyClosure` 自体は、従来の経路に入る前に、この近道を使えるかどうかを
検査するようになった。

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

3つの条件は、従来の経路が終わった直後のクロージャについて成り立つはずのことを、
そのまま表している。

- `!idris2rc2_isUnique(c)` -- ユニークな場合は、すでに最適である
  (`idris2rc2_tailcallApplyClosure` が単にフィールドへ書き込むだけ)。この高速経路が
  対象とするのは、本来なら `mkClosure` が呼ばれてしまう、非ユニークな場合だけである。
- `c->arity - c->filled == 1` -- `arg` が*最後の*引数である。つまり、成長した
  クロージャは、直後に必ず続くトランポリン呼び出しによって、無条件にただちに
  ディスパッチされる。残りの引数が2つ以上ある場合は、成長した(まだ飽和していない)
  クロージャを、後の適用のために実際に保持しなければならない。そのため通常の経路を
  使う。
- `c->arity >= 1 && c->arity <= 20` -- `idris2rc2_dispatchWithExtra` が実装している、
  型付きの `FUNn` の範囲に限定する。後述の「適用範囲」を参照。

条件が成り立つと、元のクロージャの引数は、対象関数の呼び出しに直接dupして渡される
(`idris2rc2_tailcallApplyClosure` の非ユニーク分岐が、`mkClosure` で作った置き換え用の
クロージャにコピーしていたものと、まったく同じ内容である)。元のクロージャは drop
される。このクロージャは変更されていないので、これは通常のチェック付きのdropであり、
トランポリン自身の無条件デクリメントの流儀ではない。結果は、これまでどおりトランポリン
にかけられる。この適用のために `IDRIS2RC2_Closure` が割り当てられることは、一度も
ない。

## `idris2rc2_tailcallApplyClosure` を意図的に変更しなかった理由

この変更のうち、最も正確に理解しておくべき部分であり、類推で間違えやすい部分でも
ある。最後の引数なら `mkClosure` を省く、という同じ近道を、`idris2rc2_tailcallApplyClosure`
自身の内部にも同様に適用できそうに見える。しかし、適用してはならない。

`idris2rc2_tailcallApplyClosure` は、生成されたコードが、実際に末尾位置にあるクロージャ
適用の箇所で、`idris2rc2_applyClosure` を介さずに直接呼び出す。これは、上に引用した
`Compiler.RC2.RC2.Emit` の `RApp` のケースの `InTailPosition` の腕に当たる
(`Emit.idr:1064-1065`)。常に `idris2rc2_applyClosure` を呼ぶのではなく、この場合に
*別の*入口が存在する理由は、末尾位置の適用が、飽和したクロージャを、**ディスパッチ
せずに**ボックス化されたまま C の呼び出しチェーンの上位へ返さなければならない
からである。実際のディスパッチは、あとからスタックの上位にある、回数に上限のある
別の `idris2rc2_trampoline` の `while` ループで行われる(`runtime.c:279-299`)。これは
標準的なトランポリンの技法であり、深い末尾再帰の Idris2 プログラムが C のスタックを
際限なく伸ばさないよう、このコードベース全体が頼っている仕組みである。

姉妹の仕組みとして、`rc2/doc/loop-conversion.md` の「末尾呼び出しから `goto` へ」の節
を参照してほしい。そこでは、*自己*末尾再帰や*相互*末尾再帰の呼び出しを、コンパイル時に
平坦な `goto` へ変換している。静的に分からない任意のクロージャを介した末尾呼び出し
は、実行時に、同じトランポリンの規律に沿って跳ね返される。`idris2rc2_tailcallApplyClosure` の
「ディスパッチせずに返す」という契約は、まさにこれを支えるために存在する。

仮に、高速経路のディスパッチを `idris2rc2_applyClosure` だけでなく
`idris2rc2_tailcallApplyClosure` 自体にも追加したとする。すると、末尾位置のクロージャ
適用が非ユニークかつ最後の引数の分岐に到達したとき、`idris2rc2_dispatchWithExtra` を、
`idris2rc2_tailcallApplyClosure` 自身の、まだ有効な C のスタックフレームの*内側*から
同期的に呼ぶことになる。呼ばれた対象の関数が、さらに別のクロージャ適用へ末尾呼び出し
し、それがまた `idris2rc2_tailcallApplyClosure` に入る場合を考える。自己参照する
(knot-tied な)クロージャは、まさにこの形を作る(後述の
`Test68ClosureFastPathStackSafety` を参照)。そうなると、本来は平坦で反復的な
トランポリンの跳ね返しであるべき処理が、C の再帰になり、その深さは際限なく増える。
共有された(非ユニークな)クロージャを軸にした深い末尾再帰のプログラムでは、
スタックオーバーフローの危険が、気づかないうちに再び入り込むことになる。

`idris2rc2_applyClosure` をこの方法で最適化しても安全なのは、まさに、どの分岐が実行
されても、自身の結果を常に無条件で直ちにトランポリンにかけるからである。この性質は、
今回の変更の前からあった。この関数の内部で割り当てを省いても、変わるのは最終的な
ディスパッチに*どう*到達するかだけで、ディスパッチが行われる*かどうか*や*いつ*行わ
れるかは変わらない。`idris2rc2_applyClosure` の呼び出し元は、どちらの経路でも、完全に
ディスパッチされた結果を同期的に受け取る。ディスパッチのタイミングについて観測できる
ものは何も変わらず、一時的な割り当てが取り除かれるだけである。

## 遅延評価: 別のランタイム関数が処理する

`Force` による `Delay` のサンクの評価は、`idris2rc2_applyClosure` をまったく通らない。
`idris2rc2_force`(`rc2/doc/lazy-memoization.md`)が、サンクを `idris2rc2_dispatchFn` /
`idris2rc2_trampoline` で直接ディスパッチし、結果を lazy セルに保存する。そのため、
同じセルを後で `force` すると、何も評価せずにその結果が返る。この高速経路は、
遅延評価とは関係がない。この処理では、`Delay` のクロージャに対して
`idris2rc2_applyClosure` を呼ぶことがないので、高速化の対象にも、影響を受ける対象にも
ならない。

## 適用範囲: アリティ 1..20 のみ

`idris2rc2_dispatchWithExtra` が実装しているのは、型付きの `FUNn` の範囲だけである。
これは `idris2rc2_dispatchClosure` の、型付きのswitchのケースと同じ範囲である。
アリティが20を超えるクロージャは、配列ベースの汎用の `IDRIS2RC2_FUNSTAR` 呼び出し規約
を使う(`idris2rc2_dispatchClosure` の `default:` のケース)。そのため、
`idris2rc2_applyClosure` の高速経路の条件(`c->arity <= 20`)から除外され、従来の
`idris2rc2_tailcallApplyClosure` に続けてトランポリンにかける経路を、そのまま通る。
これは今回の範囲における、既知の意図的な未対応であり、見落としではない。除外した理由
と、拡張に必要な作業については、`TODO.md` の「Performance: closure-dispatch fast path
doesn't cover arity > 20 (`FUNSTAR`)」の項目を参照。

## 参考テスト

- **`Test66ClosureFastPath` §1**(旧 `Test66ClosureFastPathMap`)。
  2000要素のリストに対する `map (addN n) xs`。`addN n` は部分適用(アリティ 2、
  filled 1)で、`map` が全要素に使い回す。そのため、最後の要素を除いて、どの適用でも
  非ユニークである。開発中に計測用のコードを入れて確認した(のちに削除済み)ところ、
  高速経路は要素ごとにちょうど1回発動した。
- **`Test66ClosureFastPath` §2**(旧 `Test67ClosureFastPathDictDispatch`)。
  同じ形だが、手書きの関数ではなく、本物のインターフェース辞書に由来するもの。
  `map (k +) xs` で、`(k +)` は、実行時の辞書から取り出した `Num` の `(+)` メソッド
  に、捕捉した定数を部分適用したものである。同様に、要素ごとに1回発動することを確認
  した。
- **`Test68ClosureFastPathStackSafety`**(`rc2/tests/Test68ClosureFastPathStackSafety/`)。
  上述の安全性の議論に対する、専用の回帰テスト。自己参照する(knot-tied な)
  `IORef (Int -> Int)` に保存されたクロージャを読み出し、**末尾位置**で再び適用する
  処理を、10,000,000 回行う。この適用はすべて、実際に非ユニークである(反復のたびに
  `IORef` 自身が、クロージャへの生きた参照を保持しているため)。したがって、
  高速経路を `idris2rc2_applyClosure` ではなく `idris2rc2_tailcallApplyClosure` に追加
  していれば、C の再帰が際限なく深くなる、まさにその形である。同じ開発中の計測で、
  高速経路の発動が**ゼロ回**だったことを確認した。これにより、ここでの適用がすべて
  手を入れていない `idris2rc2_tailcallApplyClosure` の経路を通ることが分かる。また、
  スタックオーバーフローを起こさず、約 2.3 秒で完了することも確認した。

この変更を取り込んだ時点の `verify.sh` の全体の結果は、87 件成功、既知の失敗 0 件、
失敗 0 件で、valgrind も問題なしだった。
