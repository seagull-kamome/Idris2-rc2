# コンストラクタのin-place再利用解析(`Compiler.RC2.Reuse`)

IRレベルの再利用パスに関する実装ノート。将来のセッション(あるいは
将来の自分)が、設計を再導出したり、既に発見・修正済みのバグを
再発見したりせずに完全な文脈を取り戻せるようにするために書かれた。
コミット`92078f8`(「Elevate constructor-reuse-in-place analysis to a
dedicated IR pass」)に対応する。`Compiler/RC2/Reuse.idr`のファイル
レベルのモジュールコメントが正式な要約であり、本書はそこに収まら
ない*なぜ*と*途中で何がうまくいかなかったか*を扱う。

(原文: `doc/reuse-analysis.md`。内容が乖離した場合は原文を正とする。)

## この最適化そのもの

あるコンストラクタ値が、まさにそれが照合された場所で死ぬ(その
スクルティニーの参照カウントがまさに0になろうとしている)*かつ*
その照合された枝が同じ名前の新しいコンストラクタを構築する場合、
死につつある値のヒープストレージは`free()`して`malloc()`し直す
代わりに、その場でin-placeに再利用できる -- 実行時の
`idris2rc2_isUnique(x)`チェック(`refCount == 1`)がこれをゲートし、
値が実は共有されていると判明した場合は通常のdropにフォールバック
する。これは本家RefC自身の最適化を踏襲している。RefCはこれを
C出力時に、状態を持つ名前キー付きマップを使って決定している。
rc2も元々は同じ方式だった(`Emit.idr`、`Ref EnvTracker`経由で
スレッドされる`ReuseMap : SortedMap Name String`)。これは
`RCExp.idr`自身のモジュールコメントが「Emitは純粋に機械的」と
主張しているにもかかわらず、である。本モジュールはこの矛盾を、
`RC.idr`の`annotate`が所有権を決定するのと同じ方法 -- 専用のパスが
一度だけ計算し、IRへ直接データとして焼き込み、Emit.idr はそれを
下ろすだけ -- で再利用を決定することで解消する。

## パイプライン上の位置

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.RC.normalize   (Phase 1: ANF風、ネイティブ型推論)
  -> Compiler.RC2.RC.annotate    (Phase 2: 所有権 -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse.resolveReuse   (このパス)
  -> Compiler.RC2.Emit          (純粋に機械的なRCExp -> C)
```

`Compiler.RC2.RC2`の`applyReuse`で配線されており、`toRCDef`
(それ自体が既にnormalize+annotateを行っている)の直後に`toRCDefs`
から呼ばれる。トップレベル定義1つ(`MkRCFun`/`MkRCError`)につき
一度実行される。再利用のオファーが関数境界をまたぐことは一切ない
(`MkRCCon`/`MkRCForeign`はそのまま素通りする、本体を持たないため
歩く対象がない)。

**なぜ`annotate`の*後*であって、それに畳み込まないのか**: 再利用の
判断には、annotateが*既に計算した*RDropリストを読む必要がある
(スクルティニーがまさにここで死ぬかどうかを知るため)。所有権/
借用情報を自分で再導出するのではなく。相互に絡み合わせることは
annotateが既にやった作業をやり直すことを意味する。これはセッション
の途中でユーザーと明示的に行った設計上の選択だった(正確な理由の
経緯が必要なら会話履歴参照)。代替案(`annotate`自体に直接畳み込む)
は検討されたが、利益なしに複雑さが増すとして却下された。

## IRへの追加(`RCExp.idr`)

- `RCon`の`reuseFrom : Maybe RCLocal` -- `Just sc`はこの構築が`sc`の
  ストレージを再利用しうることを意味する。Phase 1/2は常にこれを
  `Nothing`のままにする。このパスだけが値を設定する。
- `MkRConAlt`の`offersReuse : Maybe RCLocal` -- `Just sc`は、この枝
  自身のスクルティニー`sc`がここで死に、*かつ*本体のどこかで同じ
  名前のコンストラクタをもう1つ構築することを意味する。つまり
  そのdropは無条件のものではなく再利用チェックになる。これも
  Phase 1/2からは常に`Nothing`。
- `RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp` -- 新規ノード、
  このパスのみが挿入する。ある実行パス上で結局消費されなかった
  再利用オファーを解放する(兄弟の枝がそれをclaimしたか、この
  パス上には一致する`RCon`が到達可能な形で一切なかったか)。
  `idris2rc2_dropReuseConstructor(loc)`に変換される。これは`loc`が
  NULL(他所で既に解決済み)ならno-op、それ以外は実際の解放となる。

`freeLocalsR`/`countUsesR`は`reuseFrom`/`offersReuse`を数えない --
`ROp.postDrop`と同じ理屈: それらが指すローカルは既にその本来の
束縛箇所で数えられているので、もう一度数えることは冗長になる
だけで、加算的な意味を持たない。

## 決定論的な予約名(旧設計に対する鍵となる簡略化)

旧`ReuseMap : SortedMap Name String`は*コンストラクタ名*でキー付け
されていたため、予約を保持するC変数は、一致する`RCon`が発行される
時点で名前引きされる必要があり、それに伴う状態管理一式(スレッド化、
スコープ境界でのスナップショット/復元、`intersectionMap`/
`differenceMap`による絞り込み)が必要だった。

このパスはルックアップテーブルを完全に迂回する: 予約変数の名前は
*スクルティニー自身のローカルID*の純粋な関数(`Emit.idr`の
`reuseVarName sc = "reuse_" ++ varName sc`)であり、オファーする枝、
それをclaimする`RCon`、それを解放する`RReleaseReuse`のどれもが
同一に計算する -- `resolveReuse`が既に、*どの*`RCon`が特定の
オファーをclaimするかを解決し、その対応関係をデータとして直接
エンコード済みだから(`RCon.reuseFrom = Just sc`)、発行時に再発見
すべきものは何も残っていない。これはまた、オファーが旧マップで
暗黙に前提とされていた「コンストラクタ名ごとに生きている予約は
1つだけ」という制約からも解放されることを意味する(同じ
コンストラクタ名を構築する2つの異なるスクルティニーが、それぞれ
独立した予約を持てる) -- これは意図的な緩和として明記しておく
(旧設計から意図せず持ち越されたものではない)。各予約は自身の
`sc`に紐づき独立に解決されるため安全だと考えられる。

## アルゴリズム(`Reuse.idr`)

### `peelDrop` / `rewrapDrop`

`RC.idr`自身の`branchBody`(Phase 2)が生成する`RConAlt`/
`RConstAlt`/デフォルト本体はどれも、その枝の入口で死ぬローカルの
フラットなリストを保持する*たかだか1つの*先頭`RDrop`でラップ
されている -- 決して複数連なることはない。`peelDrop`はこの不変条件
を利用して、本体全体を歩くことなく枝自身のdropリストを検査・
書き換える。`Emit.idr`自身の`peelDrop`(そう、同名の関数が2つの
モジュールにそれぞれ存在する。どちらも`Core`エフェクトを必要と
しないためRCExp.idrの共有解析にまとめられていないだけで、同一の
理由で同一のことをしている)は、このパスの実行後もこの*同じ*
不変条件が保たれていることに依存しているので、ここでの書き換えは
それを保存しなければならない(実際に保存している: `rewrapDrop`は
`RDrop`ノードを0個か1個しか生成しない)。

### `resolveAlt` -- 枝ごとの適格性

ある枝は、自身のpeelされたdropリストにおいて以下が成り立つとき
適格である:

1. 自身のスクルティニー`sc`がそこに存在する(ここで死ぬ)、かつ
2. 消去された形状(NIL/NOTHING/ZERO/UNIT -- これらは実際のヒープ
   オブジェクトを持たないNULLチェックであり、再利用するものが
   何もない)のいずれでもない、かつ
3. (peel後の)本体に対する`usedConstructorsR`が、その枝*自身*が
   照合するコンストラクタ名をどこかに含んでいる。

適格な場合: `sc`はフラットなdropリストから取り除かれ(その運命は
無条件のdropではなくオファーとなる)、`offersReuse`が`Just sc`に
設定され、`tryConsume`が本体を歩いてオファーをfind-and-claim(また
は解放)する。不適格な枝(スクルティニーの形状が全く分からない
デフォルト分岐も含む)は`offersReuse = Nothing`のまま、dropリスト
も変更されない。

### `tryConsume` / `tryClaim` -- 消費者を見つける

`tryClaim`は、目的の名前を持つ(未claimの)`RCon`が1つの位置に
あることを認識する(`annotate`の`wrapDups`が新規構築された`RCon`の
周りに`RDup`の連なりをラップすることがあるので、`RDup`にラップ
されている場合も含む) -- これは一発勝負のチェックであり、探索
ではない。

`tryConsume`が実際の探索そのものである: 逐次実行ノード(`RLet`、
`RDup`、`RDrop`、`RFree`)を前方へ歩き、各値の位置(`RLet`自身の
`value` -- これは`body`より先に評価され、それ自体が構築である
可能性があるため)で`tryClaim`を試み、真の終端(`RV`、`RAppName`、
`RApp`、`RUnderApp`、`ROp`、`RExtPrim`、`RPrimVal`、`RErased`、
`RCrash`、または裸の末尾位置`RCon`)に到達したら、それをclaimする
か`RReleaseReuse`でラップする -- 関数呼び出しはここでは*常に*
行き止まりである(これは純粋にローカルな、手続き内解析なので、
呼び出し先が何をするかは見えない)。

探索が**ネストした**`RConCase`/`RConstCase`/`RCmpCase`を通過する
とき、単にその中に目的のものがないか見るだけでなく -- そのネスト
した caseの*全ての*枝/分岐を独立に再帰的に解決する(実行時には
そのどれもが実際に選ばれうるため)。つまり、ネストしたcaseの解決
結果が呼び出し元へ「まだ探索中」を報告することは決してない: その
全ての枝は最終的にオファーをconsumeするか解放するかのどちらかに
なる。これが`tryConsume`を*部分的な*探索ではなく*完全な*解決に
している理由であり、呼び出し元は残りのcaseを自分で処理する必要が
ない。

### 順序: ボトムアップであってトップダウンではない

`resolveReuse`は、外側の枝自身の適格性を決定する*前に*本体へ
再帰する。これは、外側の枝自身の`tryConsume`探索が実行される
時点で、ネストしたあらゆる機会が既に自分がclaimするはずのものを
claimし終えていることを意味する -- 外側の探索は、ネストした処理が
未claimのまま残した`RCon`ノードだけを見つけうる。内側のオファーと
競合したり、その下から二重にclaimしたりすることは決してない。この
順序の選択は意図的なものであり、「まず子を処理する」以上の
枝をまたいだ協調が一切不要である理由でもある。

## 発行(`Emit.idr`)

- `emitReuseOffer sc conArgs shouldDrop`: `idris2rc2_isUnique(sc)`
  チェックを発行し、true分岐では`sc`のストレージを`reuse_<sc>`へ
  取り戻し、(false分岐では)`conArgs`のうち生き延びるもの
  (`shouldDrop`にないもの)をdupしてから`sc`を通常どおりdropする。
- `RCon`の`reuseFrom = Just sc`は`reuse_<sc>`を直接参照するコードに
  変換される(`if (!reuse_<sc>) { reuse_<sc> = newConstructor(...); }`
  でガードされているため、予約に失敗した場合でも通常どおり確保
  される)。
- `RReleaseReuse`は`idris2rc2_dropReuseConstructor(reuse_<sc>)`に
  変換される。

### この配線中に発見された二重解放バグ

`branchBody`(`RConCase`/`RConstCase`の枝とデフォルトの共有下ろし
込みロジック)は元々、「destructureされて生き残るフィールドを
dupしてから、それらを個別にフラットにdropすることなく親を
dropする」というプロトコルを、実際に再利用がオファーされている
パスでのみ適用すべき特殊ケースとして扱っていた -- これは誤りである:
これは、スクルティニーがそこで死ぬような、マッチしたコンストラクタ
の枝*すべて*で、再利用が実際に発火するかどうかに関わらず必要で
ある。なぜなら通常の`idris2rc2_drop`は親を*再帰的に*dropし、その
全フィールドをdropしてしまうから -- 枝の後の方でまだ必要になる
フィールド(`sc->args[k]`経由でのみエイリアスされ、独立に参照
カウントされたことは一度もない)は、その親のストレージが後で
実際に再利用されるかただ解放されるだけかに関わらず、その再帰的な
解体が始まる*前に*dupが必要である。

このバグは`wasm32cmp001`/`integers`のrefc-suiteテストで実際の
`free(): unaligned chunk detected`クラッシュとして表面化した
(比較演算子は、コンストラクタを照合してからそのフィールドの
1つを使い続ける`Prelude.EqOrd`のインスタンスメソッドを経由する)。
`git show <リファクタ前のコミット>:.../Emit.idr`を読んで、元の
`addReuseConstructor`の正確な挙動(その`else`分岐 -- 「実際には
再利用をオファーしていない」ケース -- は、呼び出し元のフラットな
dropのために`shouldDrop \\ conArgs`を返す前に、無条件に
`dupVars (conArgs \\ shouldDrop)`を実行していた)を突き止め、
それを`branchBody`の無条件の挙動として復元し、再利用固有の一意性
チェックは`sc`自身のみ、`offersReuse`が設定されている場合のみの
上乗せとして層にすることで根本原因を特定した。最終的な、正しい
版については`Emit.idr`の`branchBody`自身のドキュメントコメント
参照。全19件のrefc-suiteテスト、全7件の`tests/*.idr`スモークテスト
(本家RefCとバイト完全一致)、全3件のベンチマークで検証済み。
`idris2rc2_isUnique`/`idris2rc2_dropReuseConstructor`の両方が複数の
refc-suiteテストで実際に発火することも確認済み(サイレントに死んで
いるパスではない)。

## 既知の、意図的に未修正のエッジケース

`idris2rc2_dropReuseConstructor`(解放パス)は、通常の`idris2rc2_drop`
の解体とは異なり、解放されたコンストラクタ自身のフィールドを**
再帰的にdropしない**。これはこのパスによって導入されたものではなく、
ランタイム(`support/rc2/runtime.c`)の既存の性質である -- この作業を
始める前に実装を読んで確認済み。これが意味するのは: ある予約が
claimされ(`isUnique`が成功した)が、その後結局実際に取られた実行
パス上でどの`RCon`にも消費されなかった場合(例えば兄弟のネストした
枝が代わりに実行され、`tryConsume`がこのパスに対して`RReleaseReuse`
を挿入した場合)、その今や再利用されたのち放棄されたストレージの
*フィールド*は、解放呼び出し自体によってはクリーンアップされない、
ということ。これは潜在的なギャップであり、到達不能であることは
確認されておらず、この作業の一部としては明示的に**修正していない**
-- スコープは「決定をIRレベルへ移す一方で既存の挙動を忠実に保存
する」ことであって、「途中で発見された潜在的なランタイムの問題を
修正する」ことではなかった。実際に発火することが確認された場合は、
再訪する価値がある。

## ファイル

- `rc2/src/Compiler/RC2/Reuse.idr` -- パス本体(新規モジュール)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCon.reuseFrom`、
  `MkRConAlt.offersReuse`、`RReleaseReuse`。
- `rc2/src/Compiler/RC2/RC.idr` -- Phase 1/2は常に新しいフィールドを
  適宜`Nothing`/`[]`のままにする。所有権ロジックの変更なし。
- `rc2/src/Compiler/RC2/Emit.idr` -- `reuseVarName`、
  `emitReuseOffer`、`branchBody`(後に追加されたRUnderApp/RAppName
  のクロージャ構築特殊ケース、コミット`22ade30`は再利用とは無関係
  で、たまたま同じ関数に同居しているだけ)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `applyReuse`、パイプライン配線。

## 検証方法(将来の変更後に繰り返すために)

1. `cd rc2 && source ../env.sh && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'`
2. `cd tests/refc-suite && nix-shell -p gcc gmp pkg-config --run './run.sh'` -- 19/19を
   期待する。特に`reuse`/`refc001`〜`refc003`(この最適化を直接
   行使する)と、`Prelude.EqOrd`/パターンマッチが多いコード
   (比較、`basicpatternmatch`)に注意する -- 上記の二重解放が
   実際に表面化した場所だから。
3. 生成された`tests/refc-suite/*/build/exec/`配下の`.c`を
   `idris2rc2_isUnique`と`idris2rc2_dropReuseConstructor`で
   grepし、この最適化が(消費・解放の両パスとも)サイレントに
   一度も発火しない、ということなく実際に発火していることを
   確認する。
4. 全`tests/*.idr`スモークテスト一式(`Test1Basics`〜
   `Test7CastMatrix`)を、本家`idris2 --cg refc`の出力(あるいは
   `Test7CastMatrix`については保存済みの`.expected`ファイル -- その
   RefC比較は無関係なnixpkgsのRefCランタイムのバグによりブロック
   されている、その自身のモジュールコメント参照)と突き合わせる。
