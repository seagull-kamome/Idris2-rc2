# コンストラクタのインプレース再利用解析(`Compiler.RC2.Reuse`)

(原文: `doc/reuse-analysis.md`。内容が乖離した場合は原文を正とする。)

IRレベルの再利用パスの実装ノートである。後続のセッション(将来の自分を含む)が、設計を一から導き直したり、すでに見つけて直したバグを再発見したりせずに、全体の文脈を取り戻せるように書いている。コミット`92078f8`("Elevate constructor-reuse-in-place analysis to a dedicated IR pass")に対応する。`Compiler/RC2/Reuse.idr`のファイルレベルのモジュールコメントが正式な要約であり、本書はそこに収まらない「なぜそう設計したか」と「途中で何を間違えたか」を記録する。

## 最適化の内容

コンストラクタ値が、照合されたその場で死ぬ(スクルティニーの参照カウントがちょうど0になろうとしている)場合を考える。照合した分岐がさらに同名のコンストラクタを新しく構築するなら、死にかけの値のヒープ領域は、`free()`して`malloc()`し直さずに、その場で転用できる。転用できるかどうかは、実行時の`idris2rc2_isUnique(x)`チェック(`refCount == 1`)で決まる。値が実際には共有されていた場合は、通常のdropにフォールバックする。

これはRefC自身の最適化と同じ考え方である。RefCはC出力時に、状態を持つ名前キーのマップを使って再利用を決める。rc2も当初は同じ方式を採っていた(`Emit.idr`で、`Ref EnvTracker`を通して受け渡す`ReuseMap : SortedMap Name String`)。ところが`RCExp.idr`のモジュールコメントは「Emitは純粋に機械的である」と述べており、この実装はそれと矛盾していた。本モジュールはこの矛盾を解消する。`RC.idr`の`annotate`が所有権を決めるのと同じやり方で、専用のパスが再利用を一度だけ計算し、結果をデータとしてIRに直接埋め込む。Emit.idrはそれをCに下ろすだけになる。

## パイプライン上の位置

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.InlineCExp      (whole-program inlining, before lambda lifting)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse.resolveReuse   (this pass)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

このパスは`Compiler.RC2.RC2`の`applyReuse`から呼ばれる。呼び出し位置は`toRCDefs`の中で、`toRCDef`(内部ですでにnormalizeとannotateを行う)の直後である。トップレベル定義(`MkRCFun`/`MkRCError`)ごとに一度だけ実行し、再利用の申し出(offer)が関数の境界をまたぐことはない。`MkRCCon`/`MkRCForeign`には走査すべき本体がないので、そのまま通過させる。

**annotateに組み込まず、その「後」に置く理由**: 再利用の判定には、annotateがすでに計算したRDropのリストが必要である。スクルティニーがその場で死ぬかどうかは、このリストを見れば分かる。判定をannotateに混ぜると、annotateが済ませた所有権・借用の導出をやり直すことになる。この点は、セッション中にユーザーと相談して決めた設計判断である(正確な議論の経過が必要なら会話履歴を参照すること)。`annotate`に直接組み込む案も検討したが、複雑になるだけで利点がないので退けた。

## IRへの追加(`RCExp.idr`)

- `RCon`の`reuseFrom : Maybe RCLocal`。`Just sc`は、この構築が`sc`の領域を再利用してよいことを表す。Phase 1/2は常に`Nothing`のままにし、値を設定するのはこのパスだけである。
- `RReuseOffer : FC -> (sc : RCLocal) -> (dupOnShared : List RCLocal) -> RCExp -> RCExp`。新しいノードであり、以前の`MkRConAlt.offersReuse : Maybe RCLocal`フラグによる設計を置き換えた。`sc`の一意性を実行時にチェックし、一意であれば`sc`の領域を確保したままにして、同じ形の後続の`RCon`が使えるようにする(`reuseFrom = Just sc`)。一意でなければ、`sc`を通常どおりdropする前に、`dupOnShared`の各要素(`sc`から直接分解して取り出した、単なるポインタのエイリアス)をdupする。どちらの場合も実行は`body`に続く。つまりこのノードは、到達の仕方が2通りある準備ステップであり、`RCmpCase`/`RConCase`のような2本腕の分岐ではない。挿入するのはこのパスの`resolveAlt`だけで、対象は、再利用の資格がある`RConAlt`の本体(の先頭部分)である。資格の判定手順の詳細は後述の「アルゴリズム」を参照する。
- `RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp`。これも新しいノードで、このパスだけが挿入する。ある実行経路で結局使われなかった再利用の申し出を解放する。使われない場合とは、兄弟の分岐が先に確保した場合と、その経路から一致する`RCon`に到達できない場合である。`idris2rc2_dropReuseConstructor(loc)`に下ろされる。`loc`がNULL(別の場所ですでに解決済み)なら何もせず、そうでなければ実際に解放する。`RReuseOffer`の`body`から到達できる`RCon`のうち、申し出を確保するのはちょうど1つである。ほかのすべての経路には代わりに`RReleaseReuse sc`が置かれるので、確保した領域が行方不明になることはない。

`freeLocalsR`/`countUsesR`は、`RCon`の`reuseFrom`を数えない。理由は`ROp.postDrop`と同じである。`reuseFrom`が指すローカル変数は、それ自身の束縛位置(外側の`RReuseOffer`の`sc`)ですでに数えられており、もう一度数えても冗長なだけで、加算にはならない。一方、`RReuseOffer`自身の`sc`/`dupOnShared`は数える。これらは別のフィールドから導出したものではなく、そのローカル変数の本物の使用だからである。

## 確保変数名の決定的な命名(旧設計に対する最大の単純化)

旧設計の`ReuseMap : SortedMap Name String`は、コンストラクタ名をキーにしていた。そのため、確保した領域を保持するC変数は、対応する`RCon`を出力する時点で名前から引く必要があった。これに伴って状態管理が必要になり、マップの受け渡し、スコープ境界でのスナップショットと復元、`intersectionMap`/`differenceMap`による絞り込みが必要だった。

このパスは、引き当てのための表を完全になくす。確保変数の名前は、スクルティニー自身のローカルIDだけで決まる純粋関数である(`Emit.idr`の`reuseVarName sc = "reuse_" ++ varName sc`)。申し出るalt、確保する`RCon`、解放する`RReleaseReuse`のすべてが、同じ式で名前を計算する。どの`RCon`がどの申し出を確保するかは、`resolveReuse`がすでに解決し、その対応をデータ(`RCon.reuseFrom = Just sc`)として符号化している。したがって、出力時に再発見すべきものは何も残らない。

もう一つの変化として、申し出の数に「コンストラクタ名ごとに生きた確保は1つ」という制約がなくなった。旧マップは暗黙のうちにこの制約を課していた。新設計では、同じコンストラクタ名を構築する2つのスクルティニーが、それぞれ独立に確保を持てる。これは意図的な緩和であり、安全だと考えている(各確保は自身の`sc`に結び付いていて、独立に解決される)。旧設計から意図して引き継いだ性質ではない。

## アルゴリズム(`Reuse.idr`)

### `peelDrop` / `rewrapDrop`

`RC.idr`の`branchBody`(Phase 2)が作る`RConAlt`/`RConstAlt`/デフォルト分岐の本体は、どれも、先頭に高々1つの`RDrop`を持つ。この`RDrop`は、その分岐の入口で死んでいるローカル変数をフラットなリストで保持しており、複数の`RDrop`が連なることはない。`peelDrop`はこの不変条件を利用して、本体全体を走査せずに、分岐自身のdropリストを調べたり書き換えたりする。

`Emit.idr`にも同名の`peelDrop`がある。2つのモジュールに同じ名前の関数があり、同じ理由で同じ処理をしている。どちらも`Core`のエフェクトを必要としないので、RCExp.idrの共有解析にはまとめていない。Emit側の`peelDrop`は、このパスの実行後も同じ不変条件が成り立っていることを前提にしている。したがって、ここでの書き換えはこの不変条件を保たなければならない。実際、`rewrapDrop`が生成する`RDrop`ノードは0個か1個だけである。

### `resolveAlt`: altごとの資格判定

altが再利用の資格を持つのは、そのaltのdropリスト(`peelDrop`で取り出したもの)について、次の3条件がすべて成り立つときである。

1. alt自身のスクルティニー`sc`がリストに含まれている(ここで死ぬ)。
2. erasedな形(NIL/NOTHING/ZERO/UNIT)ではない。これらは実際のヒープオブジェクトを持たないNULLチェックであり、再利用するものがない。
3. (`peelDrop`後の)本体に対する`usedConstructorsR`の結果に、alt自身が照合したコンストラクタ名が含まれている。

資格がある場合の処理は次のとおり。`sc`をフラットなdropリストから取り除く(`sc`の運命は無条件のdropではなく、申し出で決まる)。`offersReuse`を`Just sc`にする。`tryConsume`が本体を走査して、申し出を確保する(または解放する)相手を探す。資格のないaltは、`offersReuse = Nothing`のまま、dropリストにも手を付けずに残す。デフォルト分岐も資格を持たない。スクルティニーの形が分からないからである。

### `tryConsume` / `tryClaim`: 確保する相手の探索

`tryClaim`は、ある1つの位置にある、まだ確保されていない対象名の`RCon`を認識する。`annotate`の`wrapDups`は、新しく構築した`RCon`の周りに`RDup`の連鎖を巻き付けることがあるので、`RDup`に包まれた`RCon`も認識する。これは探索ではなく、その位置だけを調べる一回限りの検査である。

実際の探索は`tryConsume`が行う。`tryConsume`は、順序付けを表すノード(`RLet`、`RDup`、`RDrop`、`RFree`)を前方にたどり、値の位置ごとに`tryClaim`を試す。たとえば`RLet`の`value`は`body`より先に評価されるので、それ自体が構築式かもしれず、検査の対象になる。本物の終端に到達したときは、確保するか、`RReleaseReuse`で包む。終端とは、`RV`、`RAppName`、`RApp`、`RUnderApp`、`ROp`、`RExtPrim`、`RPrimVal`、`RErased`、`RCrash`、および末尾位置にある裸の`RCon`である。関数呼び出しは常に行き止まりとして扱う。これは手続き内に閉じた局所的な解析であり、呼び出し先が何をするかは見えないからである。

探索が**ネストした** `RConCase`/`RConstCase`/`RCmpCase`を通るときは、その内側に対象があるかを調べるだけでは済ませない。ネストしたcaseのaltや分岐のすべてを、それぞれ独立に再帰的に解決する。どの分岐も実行時に選ばれる可能性があるからである。そのため、ネストしたcaseの解決結果が、「まだ探索中」という状態を呼び出し元に返すことはない。そのcaseのすべての分岐が、申し出を確保するか解放するかのどちらかで終わる。この性質により、`tryConsume`は部分的な探索ではなく、全域的な解決になる。呼び出し側が残りのケースを処理する必要はない。

### 処理順序: トップダウンではなくボトムアップ

`resolveReuse`は、外側のalt自身の資格を判定する前に、その本体へ再帰する。したがって、外側のaltの`tryConsume`が走る時点で、ネストした側の機会はすでに、確保するものを確保し終えている。外側の探索が見つけるのは、内側の処理が確保しなかった`RCon`だけである。内側の申し出と競合したり、内側の確保を横取りして二重に確保したりすることはない。この処理順序は意図的な選択であり、「子を先に処理する」以外にalt間の調整機構が要らない理由でもある。

## 出力(`Emit.idr`)

- `emitReuseOffer sc conArgs shouldDrop`は、`idris2rc2_isUnique(sc)`のチェックを出力する。真の分岐では、`sc`の領域を`reuse_<sc>`に回収する。偽の分岐では、`conArgs`のうち生き残るもの(`shouldDrop`に含まれないもの)をdupしてから、`sc`を通常どおりdropする。
- `RCon`の`reuseFrom = Just sc`は、`reuse_<sc>`を直接参照する形に下ろされる。`if (!reuse_<sc>) { reuse_<sc> = newConstructor(...); }`で守られており、確保に失敗していても通常どおり割り当てられる。
- `RReleaseReuse`は`idris2rc2_dropReuseConstructor(reuse_<sc>)`に下ろされる。

### 配線中に見つかった二重解放のバグ

`branchBody`は、`RConCase`/`RConstCase`のaltとデフォルト分岐に共通の下ろし処理である。当初の`branchBody`は、「分解して取り出したフィールドのうち生き残るものをdupし、それらを個別にフラットdropせずに親だけをdropする」というプロトコルを、`offersReuse`が設定されている場合、つまり再利用を申し出る経路だけの特別扱いにしていた。これは誤りである。このプロトコルは、再利用が起きるかどうかにかかわらず、スクルティニーがその場で死ぬ、一致したコンストラクタの**すべての**分岐で必要になる。通常の`idris2rc2_drop`は親のフィールドをすべて再帰的にdropするからである。あるフィールドが、分岐内でこの後も必要なのに、`sc->args[k]`経由のエイリアスにすぎず独立には参照カウントされていないとする。その場合、親の領域が再利用されようと、普通に解放されようと、この再帰的な破棄の前にdupが必要である。

このバグは、refc-suiteの`wasm32cmp001`/`integers`テストで、実際に`free(): unaligned chunk detected`というクラッシュとして現れた。比較演算子は`Prelude.EqOrd`のインスタンスメソッドを経由し、そのメソッドがコンストラクタをパターンマッチしたあと、フィールドの1つを使い続けるためである。原因は、リファクタリング前のコミットの`Emit.idr`を`git show <pre-refactor commit>:.../Emit.idr`で読み、元の`addReuseConstructor`の正確な挙動を復元して突き止めた。元の実装では、`else`の枝(再利用を申し出ない場合)でも、`dupVars (conArgs \\ shouldDrop)`を無条件に行ってから、呼び出し側のフラットdrop用に`shouldDrop \\ conArgs`を返していた。この挙動を`branchBody`の無条件の動作として復元し、再利用固有の一意性チェックは、`sc`自身に対して、かつ`offersReuse`が設定されているときだけ、その上に重ねた。最終的な正しい版は`Emit.idr`の`branchBody`自身のdocコメントを参照すること。

検証は次のとおり行った。refc-suiteの全19テスト、`tests/*.idr`のスモークテスト全7件(本物のRefCの出力とバイト単位で一致)、ベンチマーク全3件。さらに、複数のrefc-suiteテストで`idris2rc2_isUnique`と`idris2rc2_dropReuseConstructor`の両方が実際に呼ばれていることを確認した(このパスが黙って死んでいるわけではない)。

## 既知のエッジケース(後述の`dropOnUnique`補遺で解決済みと確認)

`idris2rc2_dropReuseConstructor`(解放経路)は、通常の`idris2rc2_drop`による破棄とは違い、解放するコンストラクタのフィールドを再帰的にはdrop **しない**。これはこのパスが導入した性質ではなく、ランタイム(`support/rc2/runtime.c`)に元からあるものである。この節を最初に書いた時点では、未検証の潜在的な穴として扱っていた。確保が成立した(`isUnique`が成功した)のに、実際にたどった実行経路ではどの`RCon`もその確保を使わなかった場合、転用したあと放棄された領域のフィールドは、解放呼び出し自身では後始末されないように見えたのである。

**その後2回にわたって再調査し、到達不能だと確認した(未確認のままではない)。** 解析だけを行った最初の調査は、この穴は到達可能だと結論した。しかし再現コードを実際にコンパイルしてvalgrindで調べると、その結論は誤りだった。放棄する分岐で本当に死んでいるフィールドは、`idris2rc2_dropReuseConstructor`に到達するより前に、`RC.idr`自身の通常の分岐ごとの死んだ変数の後始末がすでにdropしている。したがって、ここに再帰的なdropを加えても、二重dropになるだけで何も直らない。

2回目の調査で、構造上の本当の理由が分かった。後述の`dropOnUnique`補遺は、分解したコンストラクタの全フィールドを、ちょうど2つの互いに素な集合(`dupOnShared`/`dropOnUnique`。単純な集合の差で関係付けられる)に振り分ける。気付かれないまま落ちる第三の入れ物は存在しない。さらに、どちらの集合も、確保が成立または解放されるより前に、完全に処理される(dupまたはdropされる)。`idris2rc2_dropReuseConstructor`が走る時点で、すべてのフィールドの所有権はすでに解決済みであり、再帰的にdropすべきものは残っていない。よって`idris2rc2_dropReuseConstructor`に変更は要らない。

## 補遺: `dropOnUnique`(再利用(一意)経路でのフィールドのリーク)

上記を書いたあとで発見し、修正した。`sc`から分解して取り出したものの、分岐本体のどこでも参照されないフィールドがある。読まれず、渡されず、下流でdupを要さないので`dupOnShared`にも入らない。このフィールドは、再利用(一意)経路では、dropする持ち主がいなかった。

`emitReuseOffer`の**真**(一意)の分岐は、`sc`の領域を直接`reuse_<sc>`に回収し、通常の`idris2rc2_drop(sc)`を呼ばない。一方、**偽**(非一意)の分岐は、`conArgs`のうち生き残るものをdupしたあとで`sc`をdropする。参照されないフィールドのdropは、この再帰的な破棄が暗黙のうちに担っていた。一意経路にはその役割を担うものがなく、フィールドの参照カウントは減らされないままだった。dupの取りこぼしにとどまらない、本物のリークである。

修正として、`RReuseOffer`(`RCExp.idr`)に新しいフィールド`dropOnUnique : List RCLocal`を直接追加した。この値は`Reuse.idr`の`resolveAlt`で`dupOnShared`と一緒に計算する。`sc`とその分解済みフィールドを特定する、peelしたdropリストの同じ解析を使い、その補集合を名指しする。補集合とは、本体の後続の使用に現れないために、一意経路でとくに死ぬフィールドである。処理するのは`Emit/Util.idr`の`emitReuseOffer`の一意の分岐だけで、`reuse_<sc>`を確保する直前に、`dropOnUnique`の各要素を通常どおりdropする。非一意の分岐には意図的に手を加えていない。その分岐の既存の無条件な`idris2rc2_drop(sc)`がすべてのフィールドを再帰的にdropしており、同じフィールドをもう一度dropすると、修正ではなく二重解放になるからである。

回帰テストは`rc2/tests/Test36ReuseOfferUniqueLeak.idr`である。ソケットを使わない最小の再現コードで、2つ以上のbindを持つ外側の`do`と、`if`のelse分岐にある独自のbindを持つネストした`do`から成り、まさにこの再利用の形になるように作ってある。リークが`valgrind`で消えたことを見るだけでなく、`--directive dumprcexpr`によるIRのトレースと生成されたCの確認でも裏付けた。

## 補遺: 死んだ申し出は、葉ごとではなく先頭でまとめて解放する

`resolveAlt`の資格の事前フィルタは`contains name (usedConstructorsR inner)`である。これは「同名のコンストラクタが下のどこかに現れる」という意味になる。`tryClaim`が到達できる位置はそれよりずっと少ないので、このフィルタは楽観的である。idris2-lspのビルド全体で計測すると、申し出られたスクルティニー19,011件のうち、**3,228件(17%)はどの`con ... reuse=`にも確保されない**。

`tryConsume`は、どこかで確保したかどうかを報告するようになった。死んだ申し出で変わるのは、申し出の有無ではなく、解放を置く**場所**である。

- **分岐は残す。** 死んだ申し出を、無条件に自身の「共有」経路へ畳み込む案を試したところ、**計測で性能が悪化した**。`idris2rc2_dropReuseConstructor`はフィールドに再帰せずに殻だけを解放するので、一意経路では、生き残るすべてのフィールドのdup/dropを本当に避けられる。分岐を消すと、分岐1つを節約するために、idris2-lsp自身の`dup`数が95,020から105,619に、`drop`数が84,111から92,077に増えた。この案は再び試さないこと。
- **解放を上に移す。** `tryConsume`は、確保に失敗するすべての葉の経路に`RReleaseReuse`をばらまく。死んだ申し出では、それがすべての経路である。本体を直接包む位置に`RReleaseReuse`を1つ置けば、同じ仕事ができる。殻は、たまたま実行された葉ではなく、すぐにアロケータへ戻る。また`reuseVarName sc`のCローカル変数が本体全体にまたがって生きることもなくなる。

idris2-lspのビルド全体での計測では、`releaseReuse`ノードが **33,117から10,270に**減った(22,847件、69%の削減)。1ノードは、生成されたCの`idris2rc2_dropReuseConstructor`の呼び出し箇所1つに対応する。`reuseOffer`(29,452)と`reuse=`(21,829)はどちらも変わらない。再利用の機会は1つも失っておらず、機会のなかった申し出の後始末が減っただけである。

## ファイル

- `rc2/src/Compiler/RC2/Reuse.idr`: パス本体(新規モジュール)。
- `rc2/src/Compiler/RC2/RCExp.idr`: `RCon.reuseFrom`、`MkRConAlt.offersReuse`、`RReleaseReuse`、`RReuseOffer.dropOnUnique`(上記の`dropOnUnique`補遺を参照)。
- `rc2/src/Compiler/RC2/RC.idr`: Phase 1/2は、新しいフィールドを必要に応じて`Nothing`/`[]`にしておくだけである。所有権のロジックには変更がない。
- `rc2/src/Compiler/RC2/Emit.idr`: `reuseVarName`、`emitReuseOffer`、`branchBody`(後から追加したRUnderApp/RAppNameのクロージャ構築の特別扱い(コミット`22ade30`)は再利用とは無関係で、たまたま同じ関数にあるだけである)。
- `rc2/src/Compiler/RC2/RC2.idr`: `applyReuse`、パイプラインへの組み込み。

## 検証手順(今後の変更後に繰り返すためのもの)

1. ビルドと回帰ベースライン: `CLAUDE.md`の "Build & test" 節を参照する(`idris2 --build rc2.ipkg`のあと`tests/refc-suite/run.sh`。期待値は19/19)。とくに`reuse`/`refc001`〜`refc003`(この最適化を直接実行する)と、`Prelude.EqOrd`やパターンの多いコード(比較演算、`basicpatternmatch`)に注意する。上述の二重解放が実際に現れたのはそこだったからである。
2. `tests/refc-suite/*/build/exec/`以下の生成`.c`を`idris2rc2_isUnique`と`idris2rc2_dropReuseConstructor`でgrepし、最適化が実際に働いていること(確保経路と解放経路の両方)を確認する。黙って一度も発動していない状態になっていないかを調べる。
3. `tests/*.idr`のスモークテスト一式(`Test111Basics/Basics.idr`から`Test7CastMatrix`まで)を、本物の`idris2 --cg refc`の出力とdiffする。`Test7CastMatrix`だけは、nixpkgsのRefCランタイムの無関係なバグのためにRefCとの比較ができないので、保存済みの`.expected`ファイルと比較する(詳細はそのモジュールコメントを参照)。
