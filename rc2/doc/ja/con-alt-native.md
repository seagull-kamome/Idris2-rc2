# コンストラクタdestructureフィールドのネイティブshadow化 (`Compiler.RC2.ConAltNative`)

(原文: `doc/con-alt-native.md`。内容が乖離した場合は原文を正とする。)

## 問題

関数ローカルなネイティブ型推論(`doc/native-type-inference.md`)は、
全ての`RLet`束縛ローカルについて、それが束縛される値の形
(`Types.repOf`: `ROp`/`RPrimVal`は`RNative`を提案し、それ以外は
`RBoxed`のまま)に基づいて`Rep`を決定する。しかしcase枝自身の
destructureされたフィールドは、これまで一切この処理を通っていな
かった: `Compiler.RC2.RC`自身の`normalizeConAlt`は、各フィールドを
自身の`Rep`を持たない裸の新規idとして束縛し、`Compiler.RC2.Emit`の
`emitConAltBody`は、囲む`RConCase`が持つ枝の数、スクルティニーの型
が単一コンストラクタか複数コンストラクタか、あるいはそのフィールド
自身がその後どう使われるかに関わらず、無条件に各フィールドを
`IDRIS2RC2_Value *`(Boxed)として宣言していた。

これは実際には見た目ほど悪くはなかった: `rcVarToNativeC`(`ROp`
自身のネイティブ結果オペランドのレンダリングが既に使っている
アクセサ)は、まだBoxedなローカルを、各ネイティブコンテキストでの
読み取りのたびにインラインでunboxする(`nativeUnbox ty (...)`)
既存動作を持つ -- そのため、ネイティブコンテキストで*ちょうど一度*
読まれるdestructureされたフィールドは、その一度の読み取りでのイン
ラインunbox1回分のコストで、既に事実上ネイティブだった。所有権も
完全に正しい(フィールド自身の`RDrop`は、`annotate`が自然に配置した
場所にどこであれ常に存在し、常に正しかった)。実際の、より狭い
隙間: ネイティブコンテキストで**2回以上**読まれるフィールドは、
そのunbox呼び出しを一度だけキャッシュするのではなく、読むたびに
繰り返してしまう、という点だった。

## 設計: 読み取りをキャッシュするだけで、フィールド自身の所有権には触れない

フィールド自身のBoxed宣言、および`Compiler.RC2.RC`の`annotate`
(所有権)と`Compiler.RC2.Reuse`の`resolveAlt`(コンストラクタの
in-place再利用)への自身の参加 -- どちらも既に、フィールドを通常の
Boxedローカルとして正しく扱っている -- は**一切変更しない**。この
パスは`Compiler.RC2.Reuse`の直後に新規ステップとして実行される
(`RC2.idr`自身の`toRCDefs`参照)ので、このパスが実行される時点では
両者は既にフィールドについての全てを完全に解決済みであり、このパス
はそこに既にあった「核」の計算をラップする`RLet`+`RDrop`のペアを
*追加*するだけである -- 既存の所有権ノード自身の意味を編集すること
は一切なく、それらのうちの一部が(`renameRCExp`経由で、その核へ
限定して)何を参照するかを変えるだけである。

各`RConAlt`について、ネイティブオペランドとして一貫して読まれている
と判明した各destructureフィールドについて(`Types.nativeArgType`、
`Compiler.RC2.Loop`自身のネイティブshadowループパラメータ機構が
関数全体のトップレベルパラメータについて既に使っているのと全く同じ
使用状況走査 -- 再導出ではなく直接再利用している):

1. 新規shadow idを1つ発行する。
2. altの自身の「核」(下記参照)を
   `RLet shadowId (RNative ty) (RV (RCLoc fieldId)) (RDrop
   [RCLoc fieldId] core')`でラップする -- これは*手動で*割り当てた
   `Rep`であり、`Compiler.RC2.Loop`自身の`declareLoopParam`や
   `Compiler.RC2.DualABI`自身のworker合成が、既にネイティブとして
   宣言しても安全だと分かっている値についてそうしているのと同様に、
   `Types.repOf`自身の「`ROp`/`RPrimVal`だけがNativeを提案する」
   ルールを迂回している。`Emit.idr`の`declareLet`は既に
   `declareNative`経由で任意の形の`RNative`値を扱っており、
   `emitNativeValue`自身の裸`RV`ケース(デュアルABI作業のStage 3bで
   追加、`doc/dual-abi.md`)は既にまさにこの形をレンダリングする --
   `Emit.idr`側の新規作業は不要。
3. `core'`は`core`から`fieldId`への**全ての**参照(ネイティブ
   コンテキストのものだけでなく -- `renameRCExp`は一様にリネームする)
   を`shadowId`へリダイレクトしたもので、その後
   `Compiler.RC2.Loop`自身の`stripOwnership`(直接再利用)が、それら
   の今やリネーム済みの出現に`annotate`が付けていた古い`RDup`/
   `RDrop`/`postDrop`帳簿を除去する(自身の対象は今や無効な
   `fieldId`ではなく`shadowId`である。`renameRCExp`がそれらも書き
   換えたため)。
4. destructureされたフィールドは、同じalt内で真に別個のBoxed使用を
   持つこともある(`case acc of MkAcc x y => f x (show y)`) -- その
   *参照*もshadowへリダイレクトし、`rcVarToBoxedC`自身の既に確立
   された`RNative`ケース経由で必要に応じて再box化することは、特別
   扱い不要である: フィールドが元々保持していたものを共有するの
   ではなく新規確保になるが、これはIdrisレベルのどのプログラムから
   も見えない(スカラーには観測可能なアイデンティティが無い) --
   `doc/dual-abi.md`自身の`nativePromotionFor`の記述が類似の`RLet`
   ケースについて既に依拠しているのと同じ理由付けである。

### 「核」: まず所有権/再利用ラッパーを剥がす

唯一本物の微妙な点であり、これを実装する中で見つかった唯一の本物の
バグの発生源でもある(下記参照): あるalt自身の本体は、必ずしも
直接「本物の」計算そのものではない。`Compiler.RC2.RC`自身の
`annotate`と`Compiler.RC2.Reuse`自身の`resolveAlt`はどちらも、
*まず*それを`RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer`
ノードの連鎖でラップしうる -- 最も重要なのは**`RReuseOffer`**で
あり、その自身の一意性チェックは、他の何かがフィールド自身の生存
期間に触れる*前に*実行されなければならない。したがって、上記の
`RLet`+`RDrop`ラッピングは、これら5種類の形の先頭に来るノードを
全て通り抜けた**「核」**の周りにのみ挿入される(`ConAltNative.idr`
自身の`peelWrappers`) -- ラッパー自身、およびそれが運んでいる全て
(`RReuseOffer`自身の`dupOnShared`を含む)は、完全に手つかずのまま
であり、リネームすら一切されない。

## 発見・修正したバグ

1. **最初の試み: ネイティブ昇格されたフィールドを、本物のネイティブ
   `RLet`ローカルと同様に、所有権追跡から完全に除外した -- リーク
   した。** `RConAlt`自身の`args`を`List (Int, Rep)`に変更し、
   ネイティブRepのフィールドを`annotate`自身の`owned`集合と
   `Compiler.RC2.Reuse`自身の`dupOnShared`の両方から除外し、
   destructure時に`sc->args[k]`を直接unboxすることでそれを宣言し、
   Boxedポインタを完全に破棄する、という方法を試した。全てのフィー
   ルドは、`Rep`が何であれ、コンストラクタ内部に依然*物理的に*
   Boxedとして格納されている(`sc->args[k]`は常に
   `IDRIS2RC2_Value *`である) -- `RLet`束縛されたネイティブ値(どこ
   にも解放すべきBoxedな発生源が本当に存在しない)とは異なり、
   destructureされたフィールド自身のBoxedな*出自*は、どこかで
   ちょうど1回の`idris2rc2_drop`を依然として必要とし、そうしなければ
   リークする。`tests/Test12ConAltNative.idr`自身の`step`
   (`Acc = MkAcc Int Int`をdestructureし、直後に同じ形を再構築する。
   `Compiler.RC2.Reuse`自身のコンストラクタin-place再利用パスも
   合わせて演習するよう意図的に選ばれている)に対して
   `valgrind --leak-check=full`で確認済み: 20万回の反復で約6.4MBが
   確実にリークしており、1回の`idris2rc2_mkInt64`の確保が反復ごとに
   1回リークしていた(*前回*の反復自身の再利用コンストラクタ
   フィールドの値が、`owned`からフィールドを除外したことで本来
   得られるはずだった唯一のdropを消してしまったため、一度も
   dropされないまま上書きされていた)。全て取り消し、前進修正は
   せず。完全な最初の記述は`TODO.md`自身のgit履歴参照。
2. **2回目の試み(上記の新規shadow発行+リネームという設計、最初の
   カット): 先頭の`RReuseOffer`を含む、alt本体*全体*をラップした
   -- 同じテストで、同じ規模のリークが再発した。** 新しいshadow
   ラッピング経由でフィールドを読んでdropする処理が、
   `Compiler.RC2.Reuse`自身の一意性チェックがまだ実行されて*いない*
   時点で発生してしまっていた。`Compiler.RC2.Emit`自身の
   `branchBody`(`emitConAltBody`のヘルパー)は、渡された本体が
   `RReuseOffer`で*構造的に始まっていない*場合、無条件にaltの
   コンストラクタ引数全てを`idris2rc2_dup`する(自身の
   `(Just _, RReuseOffer {}) => ...`ケースだけがそのdupをスキップし、
   完全に`RReuseOffer`自身の下降処理に委ねる -- 理由は`branchBody`
   自身のドキュメントコメント参照)。本体全体を新しい外側の`RLet`で
   ラップしたことは、この構造的マッチを壊してしまった:
   `branchBody`は(今や最外殻ではなくネストされた)`RReuseOffer`を
   認識できなくなり、実際にどちらの再利用パスが取られたかに関わらず
   無条件に`var_1`/`var_2`をdupしてしまい、一方で*本物の*
   `RReuseOffer`(新しいラッピングのさらに内側)は、それとは別に、
   今や冗長になった、正しく*条件付き*のdup判断を、その上に重ねて
   下していた -- 呼び出しごと、再利用フィールドごとに、永久に
   バランスの取れない参照が1つ余分に生じていた。同じ`valgrind`
   テストでリークを確認し、その後*ベースライン*
   (`Compiler.RC2.ConAltNative`のパイプラインエントリを一時的に
   除去)が、`RReuseOffer`自身の`else`枝の内側で*正しく*条件付きな
   同一のdupパターンを持ちつつ、既にリークフリーであることを確認
   した -- これにより、回帰が既存の何かではなく、このパス自身の
   挿入位置であったことが証明された。`peelWrappers`で修正: まず
   先頭にある全てのラッパーノード(上記「設計」節と同じ5種類の形)
   を切り離し、その下の「核」の周りにのみshadowラッピングを挿入
   し、その後再ラップして再構築する -- ラッパー自身(と
   `RReuseOffer`自身の`dupOnShared`)は今や一切リネーム対象になら
   ない。この修正の最初の草案が悩んでいた「この除外は実際に重要
   なのか」という問い全体(`dupOnShared`もフィルタするよう
   `stripOwnership`を拡張し、その後取り消した)は、結局意味の無い
   問いだったと判明した: 正しい挿入位置さえあれば、`dupOnShared`
   はそもそもこのパスによって一切触られないから。

修正後に再検証済み: `tests/Test12ConAltNative.idr`(`step`自身の
in-place再利用ケース、`repeatedRead`自身のフィールドを3回読む
ケース、`mixedUse`自身の同一フィールドをネイティブとBoxed両方で
読むケース)に対する`valgrind --leak-check=full`は`definitely lost:
0 bytes in 0 blocks`を報告する(`800 bytes in 100 blocks still
reachable`は、まさに不滅の小整数キャッシュであって、リークでは
ない)。フルのrefc-suite(19/19)と`tests/Test*.idr`スモークテスト
マトリックス全体を実際の`idris2 --cg refc`とバイト単位で再diffした
が、影響なし。スモークテストを`valgrind`で再実行中に偶然見つかった、
2つの小さな*既存*リーク(`Test1Basics`: 96バイト/5ブロック;
`Test9SelfTailLoop`: 784バイト/49ブロック)は、このパス全体の
パイプラインエントリを完全に除去した状態でも、同じサイズで存在する
ことが確認された -- 本作業とは無関係であり、ここではこれ以上調査
していない。

## ファイル

- `rc2/src/Compiler/RC2/ConAltNative.idr`(新規) -- `peelWrappers`、
  `shadowAltFields`、`assignShadowIds`、木全体を歩く
  `applyConAltNativeExp`/`applyConAltNativeAlt`など、公開される
  `applyConAltNative`。
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgTypes`/`nativeArgType`
  (既に`export`済み、無改造で再利用)と`stripOwnership`(既に
  `export`済み、無改造で再利用 -- `RReuseOffer`自身の`dupOnShared`
  もフィルタするようこれを拡張する初期の試みは、追加された後に
  取り消された。上記バグ#2参照。自身のドキュメントコメントは今や
  `Compiler.RC2.ConAltNative`がなぜそれを一切必要としないかを
  記している)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身のパイプライン配線
  (`applyReuse`の直後、`applyMutualLoop`の前に`applyConAltNative`)。
- `rc2/rc2.ipkg` -- `modules`リストへの新規モジュール追加。
- `rc2/tests/Test12ConAltNative.idr`(新規) -- `step`(再利用in-place
  との相互作用)、`repeatedRead`(フィールドをネイティブに3回読む、
  キャッシュ自体を確認)、`mixedUse`(同一フィールドをネイティブと
  Boxedコンテキストの両方で読む)。

## 検証方法

1. ビルド+回帰テストの基準線: `CLAUDE.md`の「Build & test」節参照
   (`idris2 --build rc2.ipkg`、続けて`tests/refc-suite/run.sh`、
   19/19を期待する)。
2. `tests/Test12ConAltNative.idr`は、この機能自身の正典的な
   スモークテストである -- その出力を実際の`idris2 --cg refc`自身
   の出力とバイト単位でdiffし、`Main_step`自身の生成されたCを直接
   読む: フィールドの読み取りは`int64_t var_N =
   idris2rc2_to_i64(var_M);`となり、直後に
   `idris2rc2_drop(var_M);`が続き、これは`RReuseOffer`が下降した
   `if (idris2rc2_isUnique(...))`ブロックの*後*に位置するべきで、
   *前*であってはならない -- そしてそのブロック自身の`dup`は、この
   パス全体のパイプラインエントリを除去した状態と全く同じように、
   自身の`else`枝の内側で条件付きのままであるべきである。
3. **stdoutのdiffだけでは参照リークやバランスの崩れたdupを捕まえ
   られない** -- 上記の両方のバグは、コンパイルされ、実行され、
   *正しい*結果を出力しながら、それでもリークしていた。
   `ConAltNative.idr`への変更、あるいは
   `Compiler.RC2.Reuse`自身の`resolveAlt`/`Compiler.RC2.Loop`自身の
   `stripOwnership`(どちらもここで再利用されている)への変更は、
   `tests/Test12ConAltNative.idr`に対して具体的に
   `valgrind --leak-check=full`で再検証すべきである(自身の`step`は
   20万回の反復を実行し、反復あたりのリークがノイズに埋もれず
   サマリー上で紛れもなく分かるよう意図的に大きく設定されている)
   -- `definitely lost: 0 bytes in 0 blocks`を期待する。
4. 修正が正しいと結論づける前に、`--directive noconaltnative`
   (`RC2.idr`自身の`toRCDefs`、自身のドキュメントコメント参照 --
   再ビルド不要)でこのパスを無効化した*ベースライン*に対しても
   手順3を再実行すること -- リーク(またはその不在)が実際にこの
   パスによって引き起こされているのか、それとも単にパスの有無に
   関わらず存在しているだけなのかを確認する(これはまさに、まだ
   `toRCDefs`を手で編集して`idris2-rc2`を手動で再ビルドしていた頃、
   上記の2つの小さな既存リークが本作業自身のバグから区別された
   方法そのものである)。
