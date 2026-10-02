# コンストラクタを分解したフィールドのネイティブシャドウ化(`Compiler.RC2.ConAltNative`)

(原文: `doc/con-alt-native.md`。内容が乖離した場合は原文を正とする。)

## 問題

関数ローカルなネイティブ型推論(`doc/native-type-inference.md`)は、`RLet`
で束縛されたすべてのローカル変数の Rep を、束縛される値の形に基づいて決め
る(`Types.repOf`。`ROp`/`RPrimVal` が `RNative` を提案し、それ以外は
`RBoxed` のままである)。一方、case の alt が分解して得るフィールドは、こ
の判定をまったく通っていなかった。`Compiler.RC2.RC` の `normalizeConAlt`
は、各フィールドを、Rep を持たない新しい素の id として束縛する。
`Compiler.RC2.Emit` の `emitConAltBody` は、そのすべてを無条件に
`IDRIS2RC2_Value *`(Boxed)として宣言する。外側の `RConCase` の alt がい
くつあるか、判別対象の型のコンストラクタが1つか複数か、フィールド自身がそ
の後どう使われるかは、いずれも考慮されない。

実際には、これは見かけほど悪くなかった。`rcVarToNativeC`(`ROp` のネイテ
ィブな結果のオペランドを出力する際に、すでに使われているアクセサ)は、ま
だボックス化されているローカル変数を、ネイティブな文脈で読むたびにインラ
インでアンボックスする(`nativeUnbox ty (...)`)。したがって、ネイティブ
な文脈で*ちょうど1回*だけ読まれる、分解されたフィールドは、その1回の読み
出しでインラインのアンボックスを1回払うだけで、実質的にはすでにネイティブ
だった。所有権も完全に正しい。`annotate` が自然な場所に置く、そのフィール
ド自身の `RDrop` は、常にそこにあり、常に正しい。実際の、より狭い隙間は、
ネイティブな文脈で**2回以上**読まれるフィールドにある。アンボックスの呼び
出しを一度だけ行って保持せず、読むたびに繰り返してしまう。

## 設計: 読み出しをキャッシュし、フィールド自身の所有権には触れない

フィールド自身のボックス化された宣言と、`Compiler.RC2.RC` の `annotate`
(所有権)および `Compiler.RC2.Reuse` の `resolveAlt`(コンストラクタのそ
の場再利用)への関与は、**一切変更しない**。この2つは、そのフィールドをす
でに通常のボックス化されたローカル変数として正しく扱っている。このパス
は、`Compiler.RC2.Reuse` の直後の新しいステップとして走る(`RC2.idr` の
`toRCDefs` を参照)。そのため、走る時点では、フィールドに関するすべてがそ
の2つによってすでに完全に決まっている。このパスがするのは、すでにあった
「コア」の計算を包む `RLet`+`RDrop` の組を*追加する*ことだけである。既存
の所有権ノードの意味を書き換えることはない。コアの範囲で `renameRCExp` を
通じて、いくつかのノードが参照する先を変えるだけである。

各 `RConAlt` について、ネイティブなオペランドとして一貫して読まれている
と判明した、分解された各フィールドに対して、次を行う。その判定は
`Types.nativeArgType` が行う。これは `Compiler.RC2.Loop` が、関数自身のト
ップレベルのパラメータに対するネイティブシャドウのループパラメータの仕組
みで使っているのと同じ使用状況のスキャンであり、導き直さずにそのまま再利
用している。

1. 新しいシャドウ id を払い出す。
2. alt 自身の「コア」(下記)を
   `RLet shadowId (RNative ty) (RV (RCLoc fieldId)) (RDrop [RCLoc fieldId] core')`
   で包む。`Rep` は*手動で*割り当てる。これは `Types.repOf` の
   「`ROp`/`RPrimVal` だけがネイティブを提案する」という規則を迂回するも
   のであり、`Compiler.RC2.Loop` の `declareLoopParam` や
   `Compiler.RC2.DualABI` のワーカー合成が、ネイティブとして宣言して安全
   であると分かっている値に対してすでに行っているのと同じやり方である。
   `Emit.idr` の `declareLet` は、任意の形の `RNative` の値を
   `declareNative` を通じてすでに扱える。また `emitNativeValue` の素の
   `RV` のケース(二重 ABI の取り組みの Stage 3b で追加。
   `doc/dual-abi.md`)は、まさにこの形をすでに出力できる。`Emit.idr` に新
   しい作業は要らない。
3. `core'` は、`core` のうち `fieldId` の*ネイティブな文脈*での出現だけ
   を `shadowId` に向け直したものである(`markNativeOccurrences`。
   `Loop.idr` の `nativeArgTypes`/`opNativeUsesThrough` の走査を正確に写
   したもので、集める代わりに書き換える)。残ったボックス化の文脈での出現
   は `fieldId` 自身のまま、手を付けずに残す。まず `stripOwnership`
   (`Compiler.RC2.Loop`。そのまま再利用する)が、`annotate` が `fieldId`
   に付けていた古い `RDup`/`RDrop`/`postDrop` の帳簿を消す。この帳簿は、
   ネイティブもボックス化もすべての出現がシャドウに吸収されると仮定して
   いた時点で計算されたものである。次に `reannotateFieldOwnership` が、残
   ったボックス化の文脈での出現について、`fieldId` だけの所有権をゼロか
   ら作り直す。完全な設計と、これを導入する際に見つかった2つの実バグにつ
   いては、下の「残ったボックス化の文脈での読み出しに、元のボックス化フィ
   ールドを再利用する」を参照。
4. 分解されたフィールドには、同じ alt の中に、本当に別個のボックス化の使
   用が残りうる(`case acc of MkAcc x y => f x (show y)`)。上の3の設計で
   は、その参照はシャドウに向け直されず、`fieldId` 自身を指し続ける。した
   がって、このパスがまったく走らない場合と同じく、通常の `dup`/move によ
   って元のフィールド自身の同一性を共有し続ける。そうしなければ、まだネイ
   ティブのままのシャドウを `rcVarToBoxedC` がそのつど再ボックス化するこ
   とになり、毎回新しい確保を払うことになる。

### 「コア」: 先に所有権/再利用のラッパーを剥がす

ここが、この実装で唯一本当に微妙な点であり、見つかった唯一の本物のバグ
(下を参照)の原因でもある。alt 自身の本体が、そのまま「本当の」計算であ
るとは限らない。`Compiler.RC2.RC` の `annotate` と `Compiler.RC2.Reuse`
の `resolveAlt` は、どちらも本体を `RDup`/`RDrop`/`RFree`/
`RReleaseReuse`/`RReuseOffer` のノードの連鎖で*先に*包みうる。とくに重要
なのは **`RReuseOffer`** で、その一意性の検査は、ほかの何かがフィールド自
身の生存期間に触れるより*前に*走らなければならない。したがって、上の
`RLet`+`RDrop` の包みは、この5種類の形の先頭のノードをすべて越えた先の
**「コア」**にだけ挿入する(`ConAltNative.idr` の `peelWrappers`)。ラッパ
ー自身と、それが運ぶすべて(`RReuseOffer` の `dupOnShared` を含む)には、
完全に手を触れない。名前の付け替えすら行わない。

## 見つかったバグと修正

1. **最初の試み: ネイティブに昇格したフィールドを、本物のネイティブな
   `RLet` のローカル変数と同様に、所有権の追跡から完全に除外した。これは
   リークした。** `RConAlt` の `args` を `List (Int, Rep)` に変え、ネイテ
   ィブ Rep のフィールドを `annotate` の `owned` 集合と
   `Compiler.RC2.Reuse` の `dupOnShared` から除き、分解の時点で
   `sc->args[k]` を直接アンボックスして宣言し、ボックス化されたポインタは
   完全に捨てる、という方法を試した。

   Rep にかかわらず、すべてのフィールドはコンストラクタの内部に*物理的に
   は*ボックス化されて格納されている(`sc->args[k]` は常に
   `IDRIS2RC2_Value *` である)。`RLet` 束縛のネイティブな値には、解放す
   べきボックス化された元がどこにもない。それとは違い、分解されたフィール
   ドのボックス化された*出どころ*は、どこかで `idris2rc2_drop` をちょうど
   1回必要とし、そうしなければリークする。`valgrind --leak-check=full`
   で、`tests/Test117ConAltNative/ConAltNative.idr` の `step` に対して確
   認した(`Acc = MkAcc Int Int` を分解し、すぐに同じ形を再構築する。
   `Compiler.RC2.Reuse` のコンストラクタのその場再利用の経路も試すため
   に、意図して選んだ)。200k 回のイテレーションで約 6.4MB が definitely
   lost となり、1イテレーションごとに `idris2rc2_mkInt64` の確保が丸ごと
   1つリークしていた。*前の*イテレーションの、再利用されたコンストラクタ
   自身のフィールド値が、drop されないまま上書きされるためである。フィー
   ルドを `owned` から除いたことで、本来得られるはずだった唯一の drop が
   消えていた。全面的に元へ戻した。前進して直すことはしていない。最初の
   詳しい記録は、`TODO.md` 自身の git 履歴を参照。
2. **2回目の試み(上のシャドウを払い出して名前を付け替える設計の、最初の
   版): 先頭の `RReuseOffer` を含む alt の本体*全体*を包んだ。再びリーク
   した。同じテストで、同じ規模だった。** フィールドを読み、新しいシャド
   ウの包みで drop する処理が、`Compiler.RC2.Reuse` の一意性の検査が走る
   より*前に*行われてしまった。

   `Compiler.RC2.Emit` の `branchBody`(`emitConAltBody` の補助関数)は、
   渡された本体が*構造上 `RReuseOffer` で始まっていない*場合、alt の
   con-args をすべて無条件に `idris2rc2_dup` する。その dup を省くのは
   `(Just _, RReuseOffer {}) => ...` のケースだけで、すべてを
   `RReuseOffer` 自身の低水準化に任せる(理由は `branchBody` 自身のドキュ
   メントコメントを参照)。本体全体を新しい外側の `RLet` で包んだことで、
   この構造上の一致が崩れた。`branchBody` は、(いまは最外でなく入れ子に
   なった)`RReuseOffer` を認識しなくなり、どの再利用の経路が実際に取られ
   るかにかかわらず `var_1`/`var_2` を無条件に dup した。一方、*本物の*
   `RReuseOffer`(新しい包みの内側にある)は、その上にさらに、いまでは冗
   長になった、本来は正しく*条件付きの* dup の判断を行う。その結果、再利
   用されるフィールドごとに、呼び出しのたびに、永久に釣り合わない参照が1
   つ余分にできた。

   同じ `valgrind` のテストでリークを確認した。さらに、*ベースライン*
   (`Compiler.RC2.ConAltNative` のパイプラインのエントリを一時的に外した
   もの)では、同じ dup のパターンが `RReuseOffer` 自身の `else` の枝の中
   で*正しく*条件付きになっており、すでにリークがないことも確認した。こ
   れにより、退行の原因が、以前からあったものではなく、このパス自身の挿入
   位置にあると分かった。

   修正は `peelWrappers` である。先頭のラッパーのノード(上の「設計」と同
   じ5種類の形)を最初にすべて切り離し、シャドウの包みはその下の「コア」
   にだけ挿入し、あとでラッパーをかぶせ直して再構築する。ラッパー(と
   `RReuseOffer` の `dupOnShared`)には、もう名前の付け替えがまったく及ば
   ない。この修正の最初の草稿が悩んでいた「この除外は実際に問題になるの
   か」という疑問(`dupOnShared` もフィルタするように `stripOwnership` を
   拡張し、のちに取り消した)は、意味を失った。挿入位置が正しければ、この
   パスは `dupOnShared` にそもそも一度も触れないからである。

修正後に再検証した。`tests/Test117ConAltNative/ConAltNative.idr`(`step`
のその場再利用のケース、`repeatedRead` のフィールドを3回読むケース、
`mixedUse` の同じフィールドをネイティブとボックス化の両方で使うケース)
に対する `valgrind --leak-check=full` は、`definitely lost: 0 bytes in 0
blocks` を報告する(`800 bytes in 100 blocks still reachable` は、不滅の
小さな整数のキャッシュそのものであり、リークではない)。refc-suite の全件
(19/19)と `tests/Test*.idr` のスモークテスト全体を、本物の
`idris2 --cg refc` に対してバイト単位で再度 diff した結果にも影響はなかっ
た。スモークテストを通して `valgrind` を再実行している途中で、*以前から存
在した*小さなリークが2つ偶然見つかった(`Test111Basics/Basics.idr`: 96
バイト/5ブロック。`Test110Loop/SelfTailLoop.idr`: 784 バイト/49ブロッ
ク)。このパス全体のパイプラインのエントリを完全に外しても、まったく同じ大
きさで存在することを確認した。この作業とは無関係であり、ここではそれ以上
調べていない。

3. **剥がしたラッパーに残った古い `dup`(2026-09-26)。**
   `shadowOneField` は、フィールドの古い所有権を消し(`stripOwnership`)、
   「完全に所有している」状態から作り直すが、その対象は `core` だけであ
   る。`core` の手前で剥がしたラッパーにも、古い `dup` が残りうる。

   `compare` がインライン化された `mergeBy compare` は、両方の先頭要素を
   ネイティブに読む。内側の alt のラッパーは、
   `reuseOffer v53 dupOnShared=[v56, v57]` と、それに続く `dup v56` だっ
   た。この `dup` は、`annotate` が先頭要素の最初の(借用の)読み出しのた
   めに置いたものである。その読み出しはシャドウへ移ったが、`dup` だけが
   ラッパーの中に残った。このため、2つ目のリストのボックス化された要素が
   すべてリークした(n=1000 で901ブロック)。外側の先頭要素の `dup` は
   `core` の中にあったので、正しく消えていた。

   ラッパーは、このような `dup` を除いて再構築するようになった。フィール
   ドの、所有された唯一の参照は、次のどちらかによってすでに確立されてい
   る。
   - フィールドを `dupOnShared` に挙げた `reuseOffer`。
   - フィールドを、丸ごと drop される判別対象から取り出す、最初の `dup`
     (`dup v317; drop [v312]`)。

   フィールドに対する、それ以降の先頭の `dup` は取り除く。最初の修正で
   は、フィールドの先頭の `dup` を、取り出す側のものも含めてすべて取り除
   いた。これは要素を早く解放してしまい、`sumList` のループがクラッシュし
   た。`Test117ConAltNative/ConAltNativeLeadingDup.idr` が、valgrind の下
   で両方のケースを覆う。

## 残ったボックス化の文脈での読み出しに、元のボックス化フィールドを再利用する

上の設計の4は、かつては無条件の再ボックス化を意味していた。フィールドのボ
ックス化の文脈での読み出しが昇格後も残るたびに、`rcVarToBoxedC` が、シャ
ドウ自身のネイティブな値から新しい `IDRIS2RC2_Value*` を確保していた。元
のフィールドはまだ生きており、すでに同一性を持っているのに、それを共有し
ていなかった。動機の全体は `TODO.md` の「Performance: reboxing a
native-shadowed value always allocates fresh」の項目に、このトレードオフが
最初に受け入れられた経緯は `rc2/doc/loop-conversion.md` の「Native-shadow
promotion」の節にある(構造がよく似た `Compiler.RC2.Loop` 自身のケースで
の話である)。ここでは `ConAltNative` についてだけ、これを直した。
`Compiler.RC2.Loop` 自身の、ループ持ち回りのシャドウ昇格には影響しない。
両者が同じ問題でない理由は、上記の TODO の項目を参照。直し方は、それまで1
つにまとまっていた「名前の付け替えと除去」のステップを3つに分け、まとめて
ではなく昇格するフィールドごとに実行するものである。

1. `stripOwnership (singleton fieldId)` が、`fieldId` 自身の古い所有権の
   帳簿を先に消す。以前と同じ処理だが、対象はシャドウ id の一括ではな
   く、元のフィールド id に限る。
2. `markNativeOccurrences` が、`Loop.idr` の `nativeArgTypes`/
   `opNativeUsesThrough` の走査を正確に写し、見つけたネイティブな文脈での
   出現を、型を集める代わりに書き換える。ボックス化の文脈での出現は、すべ
   て `fieldId` のまま手を付けずに残す。
3. `reannotateFieldOwnership` が、残ったボックス化の文脈での出現について、
   `fieldId` だけの所有権をゼロから作り直す。規則は2つある。1つは、
   `RC.idr` の `annotate`/`splitBorrows` と同じ「最初の出現が move し、以
   降は dup する」という規則である。もう1つは、`branchBody` が
   `RConCase`/`RConstCase` の alt に対して行う、arm ごとの「使われなけれ
   ば drop する」処理である。どちらも、`RC.idr` のように集合全体を扱う版
   ではなく、単一のローカル変数(`owned : Bool`)の追跡に特化した形で、こ
   こで導き直している。`annotate` 自体を `core` に再実行することはできな
   い。`annotate` の `RCon` のケースは `reuseFrom` を無条件に `Nothing`
   に戻すので、`Compiler.RC2.Reuse` がすでに下した決定が、気づかないうち
   に取り消されてしまうからである。

これを導入する際に、実際のバグが2つ見つかった。どちらも `valgrind` は何も
報告しなかった。コンパイルでき、実行でき、*正しい*結果を表示したのに、1つ
目はリークし、2つ目は実際にメモリを壊していた。どちらも、
`tests/Test117ConAltNative/ConAltNative.idr` に新しく足した `multiBoxedUse`
と `branchingUse` のケースで見つかった(下の「ファイル」を参照)。

1. **`reannotateFieldOwnership` の `RLet` のケースを素朴に左から右へ処理し
   た版では、`freeLocalsR` の先読みが偽の情報を見ていた。** 最初の試み
   は、所有権を `value`、`body` の順に、ソースの順序のまま素通しに受け渡
   した。dup と drop の*総数*は合っていたが、*タイミング*が誤っていた。
   `fieldId` の出現のうち、テキスト上で先に現れたものが move を受け取り、
   後のものが `dup` を受け取る。これは、実際に安全な唯一の順序とは逆であ
   る。`dup` の役目は、何かがオブジェクトを解放しうる*より前に*、余分な
   参照を確保しておくことにある。最初に生きている使用がオブジェクトの唯
   一の参照を move で受け取り、あとの使用のための `dup` を*それから*実行
   する場合を考える。最初の呼び出し先が、受け取ったものを使い終えて drop
   すると、`dup` はすでに解放されたメモリを読むことになる。`multiBoxedUse`
   (`show x ++ ... ++ show x ++ ...`。`x` をボックス化の文脈で2回読む)
   が、この形を直接再現する。`RC.idr` の `annotate` の順序に戻して直し
   た。`fieldId` が*あとで*(`body` の中で)まだ必要かどうかを、`value` を
   処理する*前に*、`freeLocalsR` による先読みで決める(`RC.idr` の
   `borrowVal` とまったく同じ)。こうして、`dup` は守るべき読み出しの後ろ
   ではなく、必ず前に置かれる。`RC.idr` の形から外れる点が1つだけ必要で
   あった。ここでの `body` は、ネイティブな文脈での `fieldId` の出現がす
   べて `markNativeOccurrences` によって別の対象へ向け直された後のもので
   ある。このため、先読みが `body` の中に出現をまったく見つけないとき
   は、`value` を実際に処理した結果をそのまま渡し、`owned` から再計算す
   ることはしない。`RC.idr` の `borrowVal` の形が再計算するのは、`value`
   が渡されたすべての出現を必ず解決するという暗黙の仮定による。この仮定
   は `RC.idr` 自身では成り立つが、ここでは成り立たない。`value` に
   `fieldId` の出現が1つもないことが、ごく普通にあるからである。
2. **`RConCase`/`RConstCase`/`RCmpCase` が、呼び出し元に誤った所有権を返
   していた。これが、同じテストで二重 drop と本物の use-after-free の両
   方を起こした。** 最初の試みは、分岐の*前*の `owned` の状態(`RConCase`
   と `RConstCase` では、判別対象自身の読み出しだけを済ませた後の状態)
   をそのまま返していた。後述の `finalizeBranch` が処理するすべての arm
   で、`fieldId` が*確実に*使い切られている点を見落としていた。arm が
   `fieldId` に一切触れない場合は drop によって、触れる場合は arm が見つ
   けたボックス化の文脈での読み出しへの move または dup によって、使い切
   られる。`branchingUse`(`case x/y of` で2つの arm を持つ。一方は分解
   したフィールドをネイティブにだけ読み、もう一方はボックス化の文脈でだ
   け読む)は、この1つのバグから、2つの失敗の形を同時に再現した。
   `shadowAltFields` の外側の `RLet` の包みは、この case が誤って報告し
   た「まだ所有されている」という古い所有権を見て、無条件の `RDrop` を追
   加した。その結果、すでに自分で drop していた arm で `fieldId` を二重
   drop した。さらに、*もう一方*の arm の、すでに生きているボックス化の
   文脈での読み出しは、取られることのない別の arm が解放するはずだった値
   の読み出しになった。この3つの case が無条件に `False` を返すように直
   した。`finalizeBranch` を過ぎた時点で、どの arm が走っても `fieldId`
   は使い切られている。呼び出し元がまだ所有しているものは、何も残ってい
   ない。

2つの修正の後に再検証した。`tests/Test117ConAltNative/ConAltNative.idr`
(`step` のその場再利用のケース、`repeatedRead` のフィールドを3回読むケー
ス、`mixedUse` の同じフィールドをネイティブとボックス化の両方で使うケー
ス、`multiBoxedUse` の dup を繰り返すケース、`branchingUse` の左右非対称
な分岐のケース)に対する `valgrind --leak-check=full` は、`definitely
lost: 0 bytes in 0 blocks` を報告する(`800 bytes in 100 blocks still
reachable` は、不滅の小さな整数のキャッシュそのものであり、リークではな
い)。refc-suite の全件(19/19)、`tests/Test*.idr` のスモークテスト全体、
`rc2/tests/bench.sh` のマイクロベンチマーク一式は、いずれも影響を受けずに
通った。

## ファイル

- `rc2/src/Compiler/RC2/ConAltNative.idr`(新規)。`peelWrappers`、
  `shadowAltFields`、`assignShadowIds`、木全体を走査する
  `applyConAltNativeExp`/`applyConAltNativeAlt` など、エクスポートされる
  `applyConAltNative`、`markNativeOccurrences`/`renameOpArgsThrough`、
  `reannotateFieldOwnership`/`finalizeBranch`、
  `countDupsNeeded`/`wrapNDups`(上の「残ったボックス化の文脈での読み出し
  に、元のボックス化フィールドを再利用する」の設計)を含む。
- `rc2/src/Compiler/RC2/Loop.idr`。`nativeArgTypes`/`nativeArgType`/
  `opNativeUsesThrough`(すでに `export` 済みで、変更せずに再利用してい
  る。`markNativeOccurrences`/`renameOpArgsThrough` は、集める代わりに書
  き換えるので、これらを呼ばず、走査を正確に写している)と
  `stripOwnership`(すでに `export` 済みで、変更せずに再利用している。
  `RReuseOffer` の `dupOnShared` に対応させるための拡張を、一度加えてか
  ら元に戻した。上のバグ2を参照。ドキュメントコメントには、
  `Compiler.RC2.ConAltNative` にその拡張が要らない理由が書いてある)。
- `rc2/src/Compiler/RC2/RC.idr`。`splitBorrows`/`annotate`/`branchBody`。
  「最初の出現が move し、以降は dup する」という所有権の規則は、
  `reannotateFieldOwnership`/`finalizeBranch` が、単一のローカル変数に特
  化して導き直している。これらを直接は呼ばない。`annotate` の `RCon` の
  ケースは `reuseFrom` を無条件に戻すので、`core` に再実行すると
  `Compiler.RC2.Reuse` の決定が取り消されるからである。
- `rc2/src/Compiler/RC2/RC2.idr`。`toRCDefs` のパイプラインの配線
  (`applyReuse` の直後、`applyMutualLoop` の前に `applyConAltNative`)。
- `rc2/rc2.ipkg`。`modules` のリストに新しいモジュールを追加した。
- `rc2/tests/Test117ConAltNative/ConAltNative.idr`(新規)。
  - `step`: その場再利用との相互作用。
  - `repeatedRead`: ネイティブに3回読まれるフィールド。キャッシュそのも
    のを確認する。
  - `mixedUse`: 同じフィールドを、ネイティブとボックス化の両方の文脈で読
    む。
  - `multiBoxedUse`: ネイティブに2回、ボックス化の文脈で2回読まれるフィ
    ールド。dup の順序のバグ専用の回帰テストである。
  - `branchingUse`: 分解したフィールドのボックス化の文脈での使用が、入れ
    子になった2つの分岐 arm のうち一方にだけ現れる。分岐の所有権のバグ専
    用の回帰テストである。

## 検証方法

1. ビルドと回帰テストの基準値。`CLAUDE.md` の「Build & test」の節を参照
   (`idris2 --build rc2.ipkg` を実行し、次に `tests/refc-suite/run.sh`
   を実行する。期待値は 19/19 である)。
2. `tests/Test117ConAltNative/ConAltNative.idr` は、この機能の標準的なス
   モークテストである。出力を、本物の `idris2 --cg refc` の出力とバイト
   単位で diff する。さらに、`Main_step` の生成 C を直接読む。フィールド
   の読み出しは `int64_t var_N = idris2rc2_to_i64(var_M);` であり、その直
   後に `idris2rc2_drop(var_M);` が続くべきである。位置は、`RReuseOffer`
   から低水準化された `if (idris2rc2_isUnique(...))` のブロックの*後*で
   あり、前には決して置かない。そのブロック自身の `dup` は条件付きのま
   ま、そのブロックの `else` の枝の中に残るべきである。このパス全体のパ
   イプラインのエントリを外した場合と、同じ形になる。
3. **標準出力の diff だけでは、参照のリーク、釣り合わない dup、
   use-after-free を捕まえられない。** このモジュールでこれまでに見つか
   ったバグは、どれもコンパイルでき、実行でき、結果としては*正しい*値を
   表示した(「見つかったバグと修正」と「残ったボックス化の文脈での読み出
   しに、元のボックス化フィールドを再利用する」の両方に、まさにこのとお
   りの実例が合計4件ある)。`ConAltNative.idr` を変更した場合と、
   `Compiler.RC2.Reuse` の `resolveAlt`、`Compiler.RC2.Loop` の
   `stripOwnership`/`nativeArgTypes`(いずれもここで再利用または写してい
   る)を変更した場合は、とくに
   `tests/Test117ConAltNative/ConAltNative.idr` に対して `valgrind
   --leak-check=full` で再確認する。その `step` は 200k 回のイテレーショ
   ンを回す。これは、1イテレーションごとのリークが、ノイズに埋もれず、集
   計にはっきり現れる大きさとして意図して選んだ値である。
   `multiBoxedUse`/`branchingUse` は、それぞれ dup の順序と分岐の所有権の
   バグ専用の回帰テストである。期待値は `definitely lost: 0 bytes in 0
   blocks` である。
4. 修正が正しいと結論づける前に、ステップ3を、このパスを
   `--directive noconaltnative` で無効にした*ベースライン*に対しても再実
   行する(`RC2.idr` の `toRCDefs` を参照。そのドキュメントコメントに書
   いてある。再ビルドは要らない)。リークがある(またはない)ことが、この
   パスのせいなのか、それとも関係なく存在するのかを確認できる。上に記し
   た、以前から存在した小さなリーク2つを、この作業自身のバグと区別したの
   は、まさにこの方法である(ただし当時は、`toRCDefs` を編集して
   `idris2-rc2` を手作業で再ビルドすることを意味していた)。
