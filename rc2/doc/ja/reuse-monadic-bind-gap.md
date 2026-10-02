# コンストラクタの再利用は、モナドの bind の継続をまたげない(調査したが、対応は見送った)

(原文: `doc/reuse-monadic-bind-gap.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.Reuse`(`rc2/doc/reuse-analysis.md` を参照)が、ベンチマーク
で支配的な実在のコードで働かない理由の調査記録である。最初に有望に見えた
修正が、このケースには当てはまらなかった理由も書いてある。この調査の結果
としてコードは変更していない。本書は、将来のセッションがこの経緯を一から
導き直さずに済むように残してある。

## 動機

`Compiler.RC2.ConAltNative` を導入したあと(`rc2/doc/con-alt-native.md`)、
外部パッケージ `idris2-missing-containers` の `benchmarkHashMap` を測り直
したところ、ほとんど変化がなかった。rc2 は RefC より、`ConAltNative` の導
入後で約36%速く、導入前は約31%だった。測定のばらつきの範囲内と思われる。
`benchmarkHashMap` の合計約16.5秒のうち、`write` フェーズだけで約10秒を占
める。ホットパスは `Data.Container.Internal.IOHashSet.replaceL2`
(`install/idris2-missing-containers/src/Data/Container/Internal/IOHashSet.idr`。
`runIOHashSet` 自身の `where` ブロックの中)で、自己再帰によってバケット
のリスト(素の `List t`)をたどる。

```idris
replaceL2 : List t -> io (r, Maybe (List t))
replaceL2 [] = do ...
replaceL2 xs@(x::xs') with (decEq k (keyfunc hs x))
  _ | Yes prf = case !(found (x ** prf)) of
    NoOp r => pure (r, Nothing)
    Remove r => pure (r, Just xs')
    InsertOrReplace r v => pure (r, Just (v::xs'))
  _ | No _ = do
      (r, Just zs) <- replaceL2 xs'
        | r@(_, Nothing) => pure r
      pure (r, Just (x::zs))
```

どちらの枝も `x::xs'` を分解し、同じ形の `::` セルを再構築する(`v::xs'`
は先頭を差し替え、`x::zs` は先頭を保ったまま末尾を作り直す)。コンストラ
クタをその場で再利用する、教科書的な題材である。ところが、実際のパッケー
ジをビルドして得た C には、どちらの再構築の近くにも `reuse_` で始まる変数
がなかった。バケットのリストを1つ進めるたびに、`idris2rc2_newConstructor`
で新しい cons セルを確保し、元のセルは無条件に解放される。本書は、その理
由の調査である。

## 最初の仮説: `with` ブロックが別の関数に持ち上げられる(述べたままの形では反証された)

Idris2 の `with` は、別のトップレベル定義(補助的な「with ブロック」関数)
へ脱糖される。これは、rc2 が `Lifted` IR を見るよりずっと前に行われる。最
初の仮説は、この呼び出しの境界が `Reuse` を妨げているというものだった。

最小の再現プログラムで、この仮説の*半分*が確認できた。同じ形で、一方は
`with`、もう一方は通常の `case` を使う2つの版を、どちらも
`idris2-rc2 --cg rc2` でコンパイルした。

```idris
-- with ブロック版: 生成された C のどこにも reuse_ 変数がない。
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) with (decEq k (key x))
  replaceL2 k v (x::xs) | Yes _ = MkKV k v :: xs
  replaceL2 k v (x::xs) | No _ = x :: replaceL2 k v xs

-- 通常の case 版: 両方の枝で reuse_var_2 が問題なく働く。
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) =
  case decEq k (key x) of
       Yes _ => MkKV k v :: xs
       No _ => x :: replaceL2 k v xs
```

これはきれいな修正に見えた。`replaceL2` を `with` でなく `case` で書き直
せばよい。この書き直しを実際のライブラリ(`install/idris2-missing-containers`)
に適用し(測定のためだけの一時的な変更で、あとで `git checkout --` で戻し
た。コミットはしていない)、同じ条件で `bench.sh --missing-containers` を
測り直した。結果は**有意な差なし**だった(`with` 版が14.62秒、`case` 版が
14.43秒。どちらもその場で測り直した値である。`ConAltNative` の測定セッシ
ョンで得た16.53秒は、単にマシンの条件がより不安定だったためで、比較の基
準にできる値ではない)。書き直したライブラリの生成 C を調べると、理由が分
かった。再構築の箇所では、やはり `idris2rc2_newConstructor` が無条件に呼
ばれていて、**そこにも `reuse_` 変数は現れない**。

したがって、本当の変数は `with` か `case` かではない。実際の関数
(`runIOHashSet` と、その `where` ブロック内の `replaceL2`)は
`HasIO io =>` による多相であり、`!` 記法(`case !(found (x ** prf)) of
...`)を使っている。これは外側の分岐を `with` で書いても `case` で書いて
も変わらない。次の節のとおり、問題になるのはこちらである。

## 根本原因: `--directive dumprcexpr` による確認

生成された C から逆算する方法では、判断に迷う点が残った(下の「補足: 再利
用は働いているが、対象のセルが違う」を参照)。そこで、実際の仕組みは RCExp
の IR から直接確認した(`idris2-rc2 --cg rc2 --directive dumprcexpr ...`。
`.c` の出力の隣に `.rcexpr` ファイルができる。`rc2/doc/reading-the-ir.md`
を参照)。実際の形に合わせた再現プログラム(`HasIO io` による多相で、副作
用を持つコールバックに `!` 記法を使う)は次のとおりである。

```idris
replaceL2 : HasIO io => Nat -> String -> (Nat -> io Bool) -> List KV -> io (List KV)
replaceL2 k v found [] = pure [MkKV k v]
replaceL2 k v found (x::xs') =
  case decEq k (key x) of
       Yes _ => case !(found k) of
                     True => pure (MkKV k v :: xs')
                     False => pure (x :: xs')
       No _ => do
         zs <- replaceL2 k v found xs'
         pure (x :: zs)
```

ダンプは次のようになる(省略してあり、外側の関数の `CONS` の alt だけを示
す)。

```
def Main.replaceL2  (fun args=["v0:Boxed", ..., "v4:Boxed"] ret=Boxed)
  case v4 of                              -- v4 = xs
    _builtin.CONS args=[v16, v17] ->      -- x::xs' を分解
      drop [v4]                           -- 無条件。reuseOffer なし
      ...
      let v30 : Boxed =
        partial Main.{replaceL2:0} missing=1 [v16, v17, v0, v1, v2]
      apply v26 v30
```

`v4`(リストのセル)は、再利用の候補として提示されることなく、無条件に
drop される。`Compiler.RC2.Reuse` の適格性の検査(`rc2/src/Compiler/RC2/Reuse.idr`
の `resolveAlt`)は、`usedConstructorsR` が alt 自身の本体のどこかに、名前
が一致するリテラルの `RCon` を見つけることを要求する(`RCExp.idr:436-451`)。
ところが `usedConstructorsR` は、あらゆる呼び出しの形(`RApp`、`RAppName`、
`RUnderApp`)に対して `empty` を返す。これは意図した設計である(`Reuse.idr`
自身のモジュールの注記に「呼び出しは、ここでは常に行き止まりである。これ
は純粋にローカルな手続き内解析であり、呼び出し先が何をするかは見えない」
とある)。実際の再構築は `Main.{replaceL2:0}` の中で起きる。これは*別の*ラ
ムダリフティング済みの定義であり、この検査からは見えない。

しかも決定的なのは、そこへ至る呼び出しが `partial ... missing=1` であるこ
とである。つまり、完全に飽和した呼び出しではなく、**本物の部分適用**であ
る。`case !(found k) of ...` は `>>=` を通って脱糖される。`>>=` のシグネ
チャ(`io a -> (a -> io b) -> io b`)が、継続を第一級のクロージャ値として
組み立てることを要求するからである。ここで `io` は多相の型変数のままで
(具体的な `IO` に単相化されない)、rc2 には、継続がちょうど1回呼ばれると
いう静的な保証がない。構文上は行儀の悪い `Monad`/`HasIO` のインスタンス
が、継続を0回や複数回呼ぶことがありうる。コンパイラは、そのすべてに対して
正しくなければならない。

## ユーザーが提案した修正と、このケースに届かない理由

自然な次の案は、`Reuse` を手続き間(interprocedural)に拡張する(はるかに
大きな作業になる)代わりに、次の条件を満たすラムダリフティング済みの定義
をインライン化することである。呼び出し箇所がちょうど1つで、*かつ*完全に
飽和した直接呼び出しで呼ばれる定義、つまり、部分適用されたクロージャとし
て捕捉されることがない定義である(より深い作用の解析なしには、そのような
クロージャが「ちょうど1回しか呼ばれない」とは限定できないため)。これを
`Reuse` が走る前に行えば、`Reuse` は複数の関数でなく、1つに統合された関数
本体を見ることになる。この方法は健全であり、`Reuse` 自体を手続き間にする
よりずっと単純である。

しかし、ここでは役に立たない。RCExp のダンプを見ると、実際の呼び出しは
`partial Main.{replaceL2:0} missing=1 [...]` であり、飽和していない。「呼
び出し箇所がちょうど1つ」という性質のほうは、これらのラムダリフティングさ
れた case ブロックの補助関数で成り立つ(経験的にも確認した。実際のパッケ
ージの生成 C で、`replaceL2` が持ち上げた補助関数はそれぞれちょうど3回現
れる。プロトタイプ、定義、呼び出し箇所1つである。一方、本当に再帰してい
る名前付きの `replaceL2` 自身は4回現れる。呼び出し箇所が、最初の呼び出し
と末尾呼び出しの2つあるためである)。失敗するのは条件の*完全飽和*のほう
で、原因は呼び出し回数のあいまいさではなく、まさにモナドの bind の継続で
ある。

## 補足: 再利用は働いているが、対象のセルが違う

実際のパッケージの生成 C を読んだ最初の印象では、ラムダリフティングされた
補助関数の中で再利用が*働いている*ように見えた(`reuse_var_0`/
`reuse_var_4` や `idris2rc2_isUnique` の検査が、実際に存在する)。RCExp の
ダンプをたどると、実際に再利用されているものが分かった。rc2 は、コンスト
ラクタが1つでフィールドが2つのボックス化された値を、すべて同じ
`_builtin.CONS` タグ付きの物理的な形で表現する。`List` の cons セルだけで
なく、たとえば2メソッドのインターフェース辞書のレコードも同様である。そし
て `Reuse` は、この形と名前で照合するのであり、元のソースレベルの型の同一
性では照合しない。

補助関数の中では、構造上 cons セルと同じ形をしたインターフェース辞書の値
が、その関数の中で完全にローカルであるため、それ自身の正当なローカルの再
利用の候補になる。これが、新しい `x::zs`/`v::xs'` のセルを作る際に使われ
る。これによって確保を1回減らせてはいるが、この調査が追っていたものとは別
のセルである。*元の*リストのセル(上の `v4`)は、この補助関数が走るより前
に、1つ上の階層ですでに無条件に drop されている。したがって、元のセルにつ
いては、確保と解放の無駄な組が残る。辞書の形をしたものの再利用は、それを
偶然、一部相殺するおまけであり、意図した再利用が起きている証拠ではない。

## さらに追求しなかった理由

実際のボトルネックに届くには、次のどちらかが必要になる。

1. 既知で信頼できる `Monad`/`HasIO` の実装を特別扱いする(たとえば具体的
   な `Prelude.IO` 自身の `>>=` は、継続を末尾位置でちょうど1回呼ぶ)。こ
   れにより `Reuse`(あるいはその前のパス)が、その特定の継続を直接の末尾
   呼び出しであるかのように扱える。範囲が狭く、やや原理に欠ける方法であ
   る。コンパイラが、使われている特定の bind の実装を偶然認識できる場合に
   しか役に立たない。また、`HasIO io =>` で一般的に書かれたライブラリのコ
   ードで、コンパイル時に具体的な `io` が分かる場面がどれだけあるかも不明
   である。
2. モナドの意味論を知る必要のない、より一般的な解析。「このクロージャは、
   唯一参照される場所で、末尾位置でちょうど1回適用される」ことを調べる。
   これは本物の手続き間解析/エスケープ解析であり、規模は、当初の二重 ABI
   のエスケープ解析の構想(`rc2/doc/dual-abi.md` の経緯を参照)に匹敵す
   る。その取り組みは、これを必要としない、より簡単な道を見つけた。

どちらも、この領域でこれまでに出荷したどれよりもはるかに大きい。しかも、
得られる利益は、1つのベンチマークの、この特定の形をした1つのホット関数に
限られる。対応は見送ることにした。似た結果のベンチマークに将来のセッショ
ンが出会ったとき、この推論の連鎖を一から導き直さずに済むように、ここに記
録しておく。

## 確認済みの回避策: 具体的な `IO` に単相化すれば、この問題は完全に避けられる(2026-09-17)

狭いコンパイラ修正が実現可能かどうかを見積もる際に、独立に再検証した(実
現可能ではなかった。上を参照。このセッションではコードを変更していな
い)。本書自身の再現プログラムの形を2版、`--directive dumprcexpr` を付
け、最適化パスをすべて無効にして(`noloop noconstfold noinline
nolateinline nospecclosure nomutualloop nodualabi noconaltnative
nodeadcode nodupmerge nosink`。もっとも生の形を見るため)並べてコンパイ
ルした。

- **`replaceL2 : HasIO io => ... -> io (List KV)`**(本書自身の形): 上に
  述べたとおりに再現した。当初の調査では書き出していなかった点が1つあ
  る。補足の節の「偶然の」再利用は、とくに `HasIO`/`Monad`/`Applicative`
  の*辞書*引数(この実行では `v4`)で起きる。これはコンストラクタが1つで
  複数フィールドのレコードなので、補足の節自身の辞書の例と同じく、リスト
  の cons セルと `_builtin.CONS` の物理的な形を共有する。本物のリスト引数
  (`v8`)は、分解される時点で、記述どおり無条件に drop される。
- **`replaceL2 : Nat -> String -> (Nat -> IO Bool) -> List KV -> IO (List KV)`**
  (本体は同一。`io` を具体的な `IO` に置き換え、`HasIO io =>` を完全に取
  り除いた): `>>=`/`!` 記法は、明示的に引き回される「world」値に対する単
  純な apply へコンパイルされ、すべてが `Main.replaceL2` 自身の1つの定義
  の中に収まる。ラムダリフティングされた継続も、クロージャも、
  `partial ... missing=N` もない。3つの再構築の箇所のすべてで、
  `reuseOffer`/`reuse=` が本物のリストのセルに対して正しく働く(どの枝で
  も `con ... reuse=v7`)。本書が述べる隙間は、具体的に `IO` のコードには
  単純に存在しない。Idris2 自身の `IO` が、インターフェース辞書を介した
  `>>=` のディスパッチではなく、world トークンを直接引き回す形でコンパイ
  ルされるからである。

### 具体的な `IO` のダンプ(隙間なし)

`Main.replaceL2 (fun args=["v4:Boxed"(k), "v5:Boxed"(v), "v6:Boxed"(found),
"v7:Boxed"(xs), "v8:Boxed"(world)])`、`_builtin.CONS` の枝(`No` の alt。
再帰して再構築する側)。

```
_builtin.CONS [cons] tag=Just 1 args=[v10, v11] ->
  reuseOffer v7 dupOnShared=[v10, v11]
  let v12 : Boxed =
    let v13 : Boxed =
      dup v10
      call Main.key [v10]
    dup v4
    call Decidable.Equality.decEq [v4, v13]
  case v12 of
    Prelude.Types.Yes [datacon] tag=Just 0 args=[v14] ->
      drop [v12]
      let v15 : Boxed =
        let v16 : Boxed =
          dup v4
          apply v6 v4
        apply v16 v8
      case v15 of
        1 ->
          drop [v10, v15]
          let v17 : Boxed =
            con _builtin.CONS [cons] tag=Just 1 [v4, v5] reuse=v7
          con _builtin.CONS [cons] tag=Just 1 [v17, v11]
        0 ->
          drop [v4, v5, v15]
          con _builtin.CONS [cons] tag=Just 1 [v10, v11] reuse=v7
    Prelude.Types.No [datacon] tag=Just 1 args=[v18] ->
      drop [v12]
      let v19 : Boxed =
        call Main.replaceL2 [v4, v5, v6, v11, v8]
      con _builtin.CONS [cons] tag=Just 1 [v10, v19] reuse=v7
```

`case !(found k) of ...` は `apply (apply v6 v4) v8` になった(world トー
クンの `v8` が、単なる追加引数として引き回される)。`True`/`False` の分岐
は、通常の `case v15 of 1 -> ... 0 -> ...` になる。すべてがこの1つの関数の
中にインラインで収まり、先頭の `reuseOffer v7` 1つが、末尾再帰の枝を含め、
その下のすべての枝を覆う。

### `HasIO io =>` のダンプ(隙間あり)

同じソースの形で、`io` を抽象のままにしたもの。`Main.replaceL2 (fun
args=["v4:Boxed"(dict), "v5:Boxed"(k), "v6:Boxed"(v), "v7:Boxed"(found),
"v8:Boxed"(xs)])`。ここでは、実際のリスト引数が `v4` でなく `v8` であるこ
とに注意する(`HasIO`/`Monad`/`Applicative` の辞書が先頭に来る)。

```
case v8 of
  ...
  _builtin.CONS [cons] tag=Just 1 args=[v20, v21] ->
    dup v20
    dup v21
    drop [v8]                                  -- <- 本物のリストのセル: 無条件に drop。reuseOffer なし
    let v22 : Boxed = ... call Decidable.Equality.decEq [v5, v23]
    case v22 of
      Prelude.Types.Yes [datacon] tag=Just 0 args=[v24] ->
        drop [v22]
        case v4 of
          _builtin.CONS [cons] tag=Just 1 args=[v25, v26] ->    -- 辞書。CONS の形をしている
            ...
            let v30 : Boxed = ...                               -- Monad 自身の >>= メソッドの適用
              let v33 : Boxed = dup v5; apply v7 v5              -- `found k`
              apply v31 v33
            let v34 : Boxed =
              partial Main.{replaceL2:0} missing=1 [v20, v21, v4, v5, v6]   -- 継続のクロージャ
            apply v30 v34                                        -- >>= がこれを呼ぶ。Reuse からは不透明
      Prelude.Types.No [datacon] tag=Just 1 args=[v35] -> ...    -- 同じ形で、{replaceL2:1}

def Main.{replaceL2:0}  (fun args=["v59:Boxed"(x), "v60:Boxed"(xs'), "v61:Boxed"(dict),
                                    "v62:Boxed"(k), "v63:Boxed"(v), "v64:Boxed"(foundResult)])
  case v64 of
    1 ->
      drop [v59, v64]
      case v61 of                                    -- v61 は捕捉された辞書(v4)であり、リストではない
        _builtin.CONS [cons] tag=Just 1 args=[v65, v66] ->
          reuseOffer v61 dupOnShared=[v65] dropOnUnique=[v66]   -- 「再利用」が働く。ただし辞書に対して
          ...
          let v74 : Boxed =
            let v75 : Boxed = con _builtin.CONS [cons] tag=Just 1 [v62, v63]  -- 新規確保。reuse= なし
            con _builtin.CONS [cons] tag=Just 1 [v75, v60]                    -- 新規確保。reuse= なし
          releaseReuse v61
          apply v73 v74
    0 ->
      drop [v62, v63, v64]
      case v61 of
        _builtin.CONS [cons] tag=Just 1 args=[v76, v77] ->
          reuseOffer v61 dupOnShared=[v76] dropOnUnique=[v77]
          ...
          let v85 : Boxed =
            con _builtin.CONS [cons] tag=Just 1 [v59, v60] reuse=v61   -- 再利用するのは辞書のセルであり、v8 ではない
          apply v84 v85
```

リストのセル(`v8`と、補助関数へ `v60` として渡されるその末尾 `v21`)は、
このトレースのどこでも再利用の対象になっていない。`{replaceL2:0}` の中の
`reuse=`/`reuseOffer` はすべて `v61`、つまり捕捉された辞書(`v4`)に対す
るものである。これは、補足の節の「再利用は働いているが、対象のセルが違
う」という発見を、独立に作った2つ目の再現プログラムでも直接確認したもの
である。

実用上の含意は次のとおりである。`HasIO io =>` で一般的に書かれていても、
実際には具体的な `IO` でしかインスタンス化されないホットパスの関数
(`Data.Container.Internal.IOHashSet` 自身の `replaceL2`/`runIOHashSet`
がそうである)は、ホット関数を `HasIO io =>` でなく `IO` に対して直接宣
言すれば、rc2 に一切手を入れずに、この隙間を今日すぐ避けられる。これはラ
イブラリ側(たとえば `idris2-missing-containers`)のソースの変更であり、
rc2 が取り繕えるものでも、取り繕うべきものでもない。シグネチャがそう言っ
ていないのに、「呼び出し側が偶然つねに `IO` を渡している」ことをコンパイ
ル時の保証として扱うわけにはいかないからである。しかし、上の2つの大規模な
コンパイラ側の選択肢に手を伸ばす前に知っておく価値のある、実際的で低リス
クの緩和策である。

## 検証方法(この調査を再開する場合)

1. `cd rc2 && source ../env.sh`
2. 最小の `HasIO io =>` 多相の再現プログラムを書く。副作用を持つコールバ
   ックに `!` 記法を使い、判別対象自身のコンストラクタを再構築する case
   の枝の中に置く(上の再現プログラムを参照)。
3. `nix-shell -p idris2 gcc gmp pkg-config --run 'build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr <file>.idr -o <out>'`
4. `build/exec/<out>.rcexpr` を読む(`rc2/doc/reading-the-ir.md` を参照)。
   分解された判別対象について、`drop [...]`(無条件)と
   `reuseOffer`/`reuse=` のどちらがあるかを探し、再構築が
   `partial ... missing=N` の呼び出し(bind の継続で、インライン化は安全
   でない)か、完全に適用された直接呼び出しかを確認する。
5. 実際のパッケージで測り直すには、`rc2/tests/bench.sh
   --missing-containers --skip-build` を使う。ソースの変更の候補ごとに、
   変更の前後を*同じセッションの中で*測る。セッションが違うとマシンの負荷
   が大きく変わるので、セッションをまたぐ比較は信頼できない。変更のたびに
   ベースラインも一緒に測り直し、以前の文書に記録された値を信用しない。
