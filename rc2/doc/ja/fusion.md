# 名前付きcase tree上のフュージョン書き換え (設計)

(原文: `doc/fusion.md`。内容が乖離した場合は原文を正とする。)

状態: **未実装。安全性を確認できなかった。** case treeは型を持たないので、規則はライブラリ関数を`Name`で照合する。しかし、照合した`Name`(例えば`Prelude.Types.foldl`)が常に`List`の実装を指すかどうかは確かめられていない。インスタンスのメソッドは`dumpnamed`/`--dumpcases`の出力で同じ名前で表示される(`Ord Int`と`Ord Integer`の`Prelude.EqOrd.<`、多数の`Prelude.Show.show`)ので、規則が`List`以外の関数に対して発火しうる。また、規則は純粋性を前提とする(「正しさの条件」を参照)。以下の内容は設計の素描にすぎない。ここに挙げた不足点を見つけるのに使った道具は`--directive dumpnamed`(実装済み)である。

## 動機

upstreamの`NamedCExp`(`Cases`フェーズ)は、リストのコンビネータをまたいだフュージョンを一切行わない。`tmp/fuse/Fuse.idr`で計測した(`--directive dumpnamed --directive noinline`はupstreamがrc2に渡すtreeを示す。`noinline`なしでは`InlineCExp`がそれをどう変えたかを示す)。

| ソース                         | treeに残るもの                                          |
|--------------------------------|---------------------------------------------------------|
| `map f (map g xs)`             | `mapAppend [Lin, f, mapAppend [Lin, g, xs]]`            |
| `map f (filter p xs)`とその逆  | `mapAppend`/`filterAppend`の入れ子                      |
| `filter p (filter q xs)`       | `filterAppend`の入れ子                                  |
| `foldl/foldr f z (map g xs)`   | `Prelude.Types.foldl [f, z, mapAppend [...]]`           |
| `foldl/foldr f z (filter p xs)`| 同様に`filterAppend`                                    |
| `sum/length/all/any (...)`     | `Foldable`レコードのCAF(`MkFoldable`)を実行時に射影する。`all`/`any`は`foldMap` + `<+>`を経由する |
| `length (map f xs)`            | `lengthPlus [0, mapAppend [...]]`                       |
| foldが消費する`[a..b]`         | `rangeFromTo`が呼び出しごとに`Ord`/`Neg`の辞書を分解し、リストを組み立てる |
| `reverse (reverse xs)`         | `reverseOnto`が2パス                                    |
| `take n (map f xs)`、`zip (map f xs) ys`、`map f (xs ++ ys)` | 中間リストが残る          |

規則が照合すべきライブラリ名に注意する。`map`/`filter`は、ソース上の再帰的な定義としてではなく、`Prelude.Types.List.mapAppend [Lin, f, xs]` / `Prelude.Types.List.filterAppend [Lin, p, xs]`として届く(`SnocList`に蓄積し、`<>>`で仕上げる)。最初の引数がリテラルの`Lin`(`%con [nil]`)であることもパターンの一部である。

## 実行される位置

```
applyLazyCaf
  -> InlineCExp          (existing: Criterion A/B inlining, case-of-case)
  -> FuseCExp            (NEW: this document)
  -> DeadArgs -> ArityRaise -> lowerProgram (lambda lifting, ...)
```

`InlineCExp`の後に置くのは、フュージョン規則が見通す必要のある`let`束縛の辞書やラッパー(`sum`、`length`、`all`、`foldMap`)を`InlineCExp`が露出させるからである。`lowerProgram`の前に置くのは、リフティングによって、規則が組み立てたり消費したりするラムダが別々のトップレベル関数になり、構造的に照合できなくなるからである。フュージョンは新たな`case`の中の`case`という入れ子を生むので、`FuseCExp`は最後にもう1回`collapse`(case-of-case)パスを走らせる。

無効化: `nofusion`(パス全体)と、規則ごとの`nofusion-<rule>`。どちらも規則表(後述)から導出されるので、規則を追加すればそのディレクティブも追加される。他のステージと同様に`Stage`(`Stage.idr`)を経由する。

## 実装の形

新しいモジュールは`Compiler.RC2.FuseCExp`(ドライバ)と`Compiler.RC2.FuseRules`(規則表)である。`Compiler.RC2.Rewrite`という名前はすでに使われている(`RCExp`のtree書き換え器)。

### 規則は1つの関数

```idris2
||| A local rewrite at one node. `Nothing` = does not apply.
record Rule where
    constructor MkRule
    name : String                       -- directive suffix: nofusion-<name>
    doc  : String                       -- one line, shown by a debug listing
    run  : FuseEnv -> NamedCExp -> Core (Maybe NamedCExp)

export
allRules : List Rule
allRules = [ knownConCase, betaReduce, inlineSingleUse
           , mapMap, filterFilter, ...
           ]
```

後で変換を追加するには、`FuseRules.idr`に`Rule`の値を1つ書き、`allRules`に加えるだけでよい。他には何も変わらない。ドライバ、ディレクティブ名、文書の一覧はすべて`allRules`から導出される。

### ドライバ

すべての定義本体(と`main`)をボトムアップに走査する。子を書き換えてから、そのノードで`allRules`の順に規則を試し、どの規則も発火しなくなるまで同じノードで繰り返す(上限8。`caseOfCaseHere`の5と同様)。走査全体は、1回の走査で何も変わらなくなるまで繰り返す(上限4)。どちらの上限も、規則の組が互いに書き戻し合う場合でも停止を保証するためだけにある。上限に達したら規則のバグであり、`logLevel` 2でログを出す。

`FuseEnv`は、規則が正当に必要とするものだけを持つ。

- `defs : SortedMap Name NamedDef`: `{csegen:18}`のようなCAFを見通し、辞書レコードのコンストラクタタグを読むため。
- 新しい束縛子のための`Fresh`カウンタ(`InlineCExp`のものを再利用する。そこからexportするか、`Compiler.RC2.Util`に移す)。
- `newDefs : Ref NewDefs (List (Name, FC, NamedDef))`: 後述のティアBだけが使う。ティアAの規則はこれに触れない。

### パターンヘルパー(規則を短くする部分)

規則は、それが実装する等式のように読めるべきである。`FuseRules.idr`に、すべて純粋な小さな照合関数と構築関数の集合を置く。

```idris2
callOf  : Name -> NamedCExp -> Maybe (List NamedCExp)       -- NmApp (NmRef n) args
isLin   : NamedCExp -> Bool                                 -- the nil constructor
mapOf   : NamedCExp -> Maybe (NamedCExp, NamedCExp)         -- (f, xs) from mapAppend [Lin,f,xs]
filterOf: NamedCExp -> Maybe (NamedCExp, NamedCExp)
lam2    : (NamedCExp -> NamedCExp -> NamedCExp) -> Core NamedCExp   -- \a => \b => body, fresh binders
app1    : NamedCExp -> NamedCExp -> NamedCExp               -- curried application
```

また、ライブラリ名の表を1つ置く。これでupstreamでの名前の変更は1行の修正で済み、名前が`defs`にないときにはサニティチェックが警告を出せる。

```idris2
namesMapAppend : Name   -- Prelude.Types.List.mapAppend
namesFilterAppend, namesFoldl, namesFoldr, namesLengthPlus, namesReverseOnto, ...
```

treeの中では、関数引数の適用は*カリー化*されている(`((f [acc]) [x])`)。そのため、構築関数はすべてこの形を出力し、`f [acc, x]`とは決して書かない。

## 規則

依頼に従い、優先度は「すべて同じ」である。規則は重要度ではなく、必要とするものによって分類している。

### ティア0: 前提となる規則(本来の規則を適用可能にする)

| 規則              | 効果                                                                   |
|-------------------|------------------------------------------------------------------------|
| `knownConCase`    | `case x of MkFoldable a b ..`で、`x`が`%con [record]`に`let`束縛されている(またはそのCAFである)もの -> フィールドを代入した選択肢にする。`Foldable List`の辞書を経由する`sum`/`length`/`foldr`を、素の`Prelude.Types.foldl`/`foldr`の呼び出しに変えるのはこの規則である。 |
| `betaReduce`      | `(%lam x b) [a]` -> `let x = a in b`。アトムに適用されている場合は代入する。 |
| `inlineSingleUse` | `let x = e in ... x ...`で、出現がちょうど1回、ラムダの下になく、束縛と使用の間に作用がないもの -> 代入する。`InlineCExp`は引数を束縛する(`rc2inl:198`)ので、`foldl`の下にある`mapAppend`が変数の陰に隠れてしまう。そのためにこの規則が必要である。 |
| `foldMapToFoldl`  | `Prelude.Types.foldMap [mon, f, xs]` -> `foldl (\acc e => acc <+> f e) neutral xs`。`all`/`any`/`concatMap`をfoldの規則にさらす(ライブラリでもすでにこのように定義されている)。 |

`knownConCase`は、`ConstFold`の既知コンストラクタの畳み込み(`RCExp`)を名前付きtreeに持ち上げたものである。「コンストラクタCのi番目のフィールド」の処理がうまく切り出せるならそれと共有し、そうでなければ両者を結合しない。

### ティアA: 新しい呼び出しと合成したラムダ、新しい定義はなし

これらの規則は、*既存の*ライブラリ関数の呼び出しを、合成した関数引数で組み立て直すだけである。書き換えの後、`SpecClosure`(`doc/speculative-closure-specialization.md`)が`foldl`/`mapAppend`をクロージャ引数ごとに複製し、`Loop`が特殊化した再帰をループに変える。そのため、新しい仕組みなしに結果はタイトなループになる。

```
mapMap        mapAppend [Lin, f, mapAppend [Lin, g, xs]]
              => mapAppend [Lin, \x => f (g x), xs]
filterFilter  filterAppend [Lin, p, filterAppend [Lin, q, xs]]
              => filterAppend [Lin, \x => case q x of True => p x; _ => False, xs]
foldlMap      foldl [f, z, mapAppend [Lin, g, xs]]
              => foldl [\acc x => f acc (g x), z, xs]
foldlFilter   foldl [f, z, filterAppend [Lin, p, xs]]
              => foldl [\acc x => case p x of True => f acc x; _ => acc, z, xs]
foldrMap      foldr [f, z, mapAppend [Lin, g, xs]]   => foldr [\x r => f (g x) r, z, xs]
foldrFilter   foldr [f, z, filterAppend [Lin, p, xs]]
              => foldr [\x r => case p x of True => f x r; _ => r, z, xs]
lengthMap     lengthPlus [n, mapAppend [Lin, g, xs]] => lengthPlus [n, xs]
lengthFilter  lengthPlus [n, filterAppend [Lin, p, xs]]
              => foldl [\n x => case p x of True => n + 1; _ => n, n, xs]
revRev        reverseOnto [Lin, reverseOnto [Lin, xs]] => xs
```

(treeの中では`reverse`は`reverseOnto [Lin, _]`である。`sum`、`all`、`any`には専用の規則は要らない。ティア0の後ではこれらは`foldl`の呼び出しになり、`foldl*`の規則が適用される。)

`foldl`/`foldr`の規則はすべて同じ形、つまり「ステージの連鎖の上のfold」をしている。そのため、生産者ごとに1つずつ書くのではなく、*ステージ*(次節)を受け取る`foldOverStage`として一度だけ書く。上の`foldlMap`と`foldlFilter`は、表に挙げた2つのインスタンスにすぎない。

正しさの条件。それぞれ規則に文書化する。

- **純粋性。** 規則は`f`と`g`の呼び出し順序を入れ替える(`g x1; g x2; ...; f x1`ではなく`g x1; f x1; g x2 ...`になる)。これらが純粋かつ全域であれば健全であり、GHCの`RULES`と同じ前提である。`f`/`g`の中の`unsafePerformIO`/`trace`は保存されない。`lengthMap`はさらに`g`を完全に捨てる。
- **共有。** 中間リストに他の消費者があってはならない。入れ子の引数は構成上ちょうど1つの消費者を持つ。`let`束縛されたものは`inlineSingleUse`が扱い、出現が2回以上なら拒否する。
- **正格性。** treeは正格なので、失われる遅延性はない。フュージョンしたfoldは、各要素を以前と同じ時点かそれより後に評価し、前倒しすることはない。
- **スタックの振る舞い。** `map`の上の`foldr`は元どおり非末尾再帰のままであり、`foldl`はループのままである。悪化するものはない。

### ティアB: 生成したループが必要なもの(フェーズ2)

合成した形を受け取る既存のライブラリ関数がない場合である。リストの生産者としての`map f (filter p xs)`、ソースとしての`[a..b]`、`take n (map f xs)`、`zip (map f xs) ys`がこれにあたる。これらには新たに生成した自己再帰の定義が必要であり、合成したラムダの自由変数を追加のパラメータに変え(手作業による小さなラムダリフティング)、新しい定義を`newDefs`に加える。

ティアBは意図的にフェーズ1に含めていない。実装する場合も、生産者と消費者の組ごとの規則にすべきではない。ステージの連鎖を使う。

```idris2
data Source = Xs NamedCExp | Range Lo Hi
data Stage  = SMap NamedCExp | SFilter NamedCExp
data Sink   = FoldL f z | FoldR f z | Length | ToList     -- ToList keeps SnocList accumulation
```

`recognise : NamedCExp -> Maybe (Source, List Stage, Sink)`は入れ子のライブラリ呼び出しを剥がし、`emit`は連鎖全体に対して1つのループを生成し、要素ごとにステージを順に適用する。新しいステージやソースを追加するには、認識関数の節と`emit`の節を1つずつ足せばよく、すべての消費者との組ごとに新しい規則を作る必要はない。ティアAはちょうど「新しい定義が要らない」という特殊な場合であり、両者は最終的に`recognise`を共有するべきである。

## テスト

- `rc2/tests/`の下にテストディレクトリを1つ置く(例: `TestNNNFusion`)。`Fuse.idr`のケースを実行時の出力とともに含める(既存のdiffによる判定)。フュージョンが結果を変えてはならないので、どの規則にも、自明でない`f`/`g`/`p`を使うケースを少なくとも1つ、フュージョンが発火して*はならない*ケース(共有された中間リスト、`unsafePerformIO`による作用のあるラムダ)を1つ用意する。
- 構造の検査: `--directive dumpnamed`でコンパイルし、`mapAppend` / `filterAppend`がもう入れ子になっていないことを確かめる。例えば`grep -c`に基づく期待値ファイルを使う。その置き場所はverify.shの期待出力の慣習である。また`nofusion`でもコンパイルし、実行時の出力をフュージョンしたものとdiffで比べる。
- 前後で`verify.sh`と`bench.sh`を実行する。規則は何も遅くしてはならない(BENCHMARKS.md)。

## 未解決の問題

1. 上記の純粋性の前提(と`lengthMap`が`g`を捨てること)は、プロジェクトのデフォルトとして許容できるか、それとも規則ごとのオプトインにするか。
2. フェーズ2(生成したループ)は必要か、それとも当面はティアAと`SpecClosure`で十分か。
3. ライブラリ名は文字どおりに照合する。upstreamでの名前の変更が規則を黙って無効にすることへの対策として、`Names`表とデバッグ用チェック(サンプルに対する`dumpnamed`の実行)を提案している。
