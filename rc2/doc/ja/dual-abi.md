# デュアル呼び出し規約(`Compiler.RC2.DualABI`)

rc2の「デュアル(Boxed/ネイティブ)関数呼び出し規約」に関する実装ノート
-- ネイティブ表現を、自己末尾呼び出しの`goto`(こちらは
`Compiler.RC2.Loop`自身の仕事、`doc/loop-conversion.md`参照)だけでなく、
*通常の*関数呼び出し境界を越えて運べるようにする取り組みについて。
将来のセッション(あるいは将来の自分)が、設計を再導出したり既に発見・
修正済みのバグを再発見したりせずに完全な文脈を取り戻せるようにする
ために書かれた。ブランチ`dual-abi`に対応する。本書は*生きた文書*で
あり、後続のStageが完成するたびに更新される -- 現時点で何が実装済みで
何がまだ計画段階かは下記「ステータス」を参照。

(原文: `doc/dual-abi.md`。内容が乖離した場合は原文を正とする。
`CLAUDE.md`自身のドキュメント索引も参照。本ファイルを編集する際は
両方を更新すること。)

## 問題

ネイティブ型推論(`Compiler.RC2.Types`、`doc/native-type-inference.md`)
は*1つの関数自身の本体の内部でのみ*適用される -- 関数の引数と戻り値は
常にBoxedなので、ネイティブ表現に適格な値も呼び出し境界を越える瞬間に
box化され、呼び出し先がそれを読む瞬間に再びunbox化される。
`Compiler.RC2.Loop`自身のネイティブshadow昇格(`doc/loop-conversion.md`)
は、*ループ自身が持ち回る*パラメータ(1つのC関数の内部にある、ある
反復と次の反復の間の境界)についてはこの往復を既に排除しているが、
2つの異なる関数の間にある通常の(末尾再帰ではない)呼び出しは、依然
毎回フルコストを支払う。

典型的なターゲットは`fib`である:

```idris
fib : Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
```

末尾再帰ではない(どちらの再帰呼び出しも`+`の内側にある)ため、
`Compiler.RC2.Loop`は一切これに触れない。関数本体全体 -- 比較、減算、
加算 -- が既存のネイティブ型推論機構によって既にネイティブRep化されて
おり、それは再帰呼び出しのオペランド値が元々どこから来たかに関係なく
変わらないにもかかわらず、呼び出しのたびに引数はboxされ、結果もbox
されて戻る。

## 設計: worker/wrapper分割(GHCの先例)

ネイティブなパラメータおよび/または戻り値の対象となる関数それぞれに
ついて、1つではなく**2つ**のC関数を生成する:

- **wrapper**: 関数自身の元々の、変更されないBoxedシグネチャ -- 既存
  のあらゆる呼び出し元(クロージャ、FFI、間接ディスパッチ、特に書き
  換えられなかった呼び出しサイト全て)が引き続き使い続けるもの。
  本体は薄いシム: 適格な各引数を変換し、workerを呼び出し、必要なら
  結果を変換して戻す。
- **worker**: 新規に合成された、内部専用の関数。適格なパラメータ/
  戻り値はそれ自身のネイティブなC型を直接使い、それ以外はBoxedの
  まま。本体が*本物の*ロジック -- 元の関数自身の本体のコピー。

これは古典的なworker/wrapper変換である(GHCも厳密性駆動のunboxingに
同じ発想を使う)。既にネイティブ表現を持っている(あるいはそれしか
必要としない)直接・飽和呼び出しサイトは、wrapper自身の変換の手間を
一切スキップしてworkerを直接ターゲットにできる -- **この書き換えは
Stage 4の仕事であり、まだ実装されていない**。下記「ステータス」参照。

### なぜ全プログラム規模の不動点が不要なのか

当初の計画メモ(`TODO.md`の本作業以前の「Dual calling convention」
エントリ参照)は、これに「エスケープ解析 + 不動点シグネチャ推論パス」
という古典的な相互手続き型の厳密性/unboxing解析機構が必要だと想定
していた。しかし実際には、**どちらの**適格性判定も、関数を跨いだ
反復を一切必要とせず、1関数ずつ*局所的に*答えられることが分かった:

- **パラメータ自身の適格性**は、*その関数自身の本体*がそれをどう
  読んでいるかだけに依存する: それが一貫してネイティブコンテキストの
  `ROp`/`RCmpCase`オペランドとして使われているか? これはまさに
  `Compiler.RC2.Loop`自身の`nativeArgType`が問うている質問を、ループ
  持ち回りパラメータだけでなく*全ての*トップレベルパラメータについて
  問うているだけである。他のいかなる関数についての情報も無関係。
- **末尾位置の戻り値自身の適格性**は、*演算子自身の*型タグ
  (`Types.opResultRep`)から来ており、これはオペランドがどこから来た
  かに一切依存しない。`fib(n-1) + fib(n-2)`は、`fib`自身がネイティブ
  値を返すと分かっているかどうかに関係なく、*既に*ネイティブRep化
  された`Add`である -- 既存のネイティブ型推論機構が、呼び出し境界の
  問題とは独立にそう判断済みだからである。

局所的には決して判定できない唯一のケース -- それ自身の算術を一切
含まない*純粋な*末尾呼び出しの委譲(`g x = h x`、この場合`g`自身の
戻り値の適格性は本当に`h`に依存する)-- は、実在する意図的なv1の
制限であり、不動点を追いかけるのではなく非適格のままにしてある。
既存のネイティブRepタグ付けが`ROp`/`RCmpCase`を通じてオペランドの
出自に関係なく既に伝播していることを踏まえると、このより狭いケースは
実運用上比較的稀だと考えられる -- プロファイリングでそうでないと
分かれば見直す。

## IRへの追加

### `MkRCFun`の新しい形(Stage 1)

```idris
MkRCFun : (args : List (Int, Rep)) -> (retRep : Rep) -> RCExp -> RCDef
```

元は`(args : List Int) -> RCExp -> RCDef`(暗黙に全てBoxed)だった。
`RLoop`自身の「自分自身のRepを持ち回る」形を、単一ループではなく
関数全体の粒度でミラーしたもの。既存の全ての構築サイト(`RC.idr`の
`normalizeDef`、`MutualLoop.idr`のマージ関数と各メンバーのwrapper)は
一様に`RBoxed`を供給し、以前の暗黙の挙動と完全に一致する -- 何も
実際にこの新しい形を使わない*前に*、純粋な、バイト同一のリファクタ
リングとして着地させた(`master`自身のコンパイラ出力とファイル単位で
突き合わせて検証済み)。`Compiler.RC2.Loop`自身のStage 1と同じ規律。

### `RAppNameRep`(Stage 3a)

```idris
RAppNameRep : FC -> Name -> (argReps : List Rep) -> (retRep : Rep) -> List RCLocal -> RCExp
```

`name`自身のworkerへの直接・飽和呼び出し: `argReps`/`retRep`は、
*この特定の呼び出し*が各引数と自分自身の結果をどう表現するかを
記述する(`RNative ty`はそこで生のネイティブ値を読み書きし、`RBoxed`
は通常の`RAppName`と同じように振る舞う)。クロージャ構築位置
(`RUnderApp`、あるいは`tryBuildClosureInto`がクロージャへ遅延させ
得たであろう末尾位置)では決して有効にならない -- クロージャ自身の
引数スロットは常に`IDRIS2RC2_Value *`しか保持できないため、ネイティブ
な引数を必要とする呼び出しはその形では決して表現できない。
`Compiler.RC2.DualABI`だけがこれを生成し、そのパスは常に
`Compiler.RC2.Loop`の後に厳密に実行される(下記「パイプライン上の
位置」参照) -- それより前のパスはこのノードを構築も想定もしていない
ため、既存の全ての網羅的な`RCExp`パターンマッチ(`RC.idr`の
`annotate`、`Compiler.RC2.Loop`の`renameRCExp`)には、既存の
`RLoop`/`RLoopContinue`ケースと同じ理由で、防御的な素通しケースが
追加されている。

## パイプライン上の位置

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (全プログラム inline化, Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF形式化, ネイティブ型推論)
  -> Compiler.RC2.RC.annotate     (Phase 2: 所有権 -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (コンストラクタのreuse-in-place)
  -> Compiler.RC2.ConAltNative    (ネイティブシャドウなフィールドキャッシュ)
  -> Compiler.RC2.MutualLoop      (相互末尾再帰 -> 1つに統合された関数)
  -> Compiler.RC2.Loop            (自己末尾呼び出し -> RLoop/RLoopContinue,
                                    加えてネイティブシャドウ昇格)
  -> Compiler.RC2.DualABI         (worker/wrapper合成, 呼び出し箇所書き換え -- 本モジュール)
  -> Compiler.RC2.Emit            (純粋に機械的な RCExp -> C)
```

`DualABI`は`Loop`の*後に*動く -- これは、自己末尾再帰関数自身の
パラメータ適格性を、再導出するのではなく`Compiler.RC2.Loop`自身が
既に決定済みの`RLoop.loopParams`から直接読み取れるようにするため
(下記`paramEligibility`参照)。また`MutualLoop`の後にも動き、その
パス自身が合成したマージ関数をworker合成から明示的に除外しなければ
ならない -- 下記「Stage 3自身の計画を変えた発見」参照。

## Stage 2: 適格性解析(`paramEligibility`/`returnEligibility`)

読み取り専用; 何も合成・書き換えせずに適格性だけを決める。Stage 3の
より危険な書き換えの上に何かを構築する前に、新しい`--directive
dumpdualabi`デバッグダンプ(`--directive dumprcexpr`をミラーし、
`<outfile>.dualabi`を書き出す)経由で検証済み -- 所有権剥奪/コード
生成のバグと絡み合ってしまう前の、安く直せる段階で設計ミスを捕まえる
ため。

### `paramEligibility : List Int -> RCExp -> List (Int, Maybe PrimType)`

`Compiler.RC2.Loop`によって既に`RLoop`でラップされた本体の場合:
その答えをループ自身の`loopParams`から位置的に直接読み取る --
`RLoop`自身の`initial`は常に、各ループパラメータの初期値を*同じ位置*
のトップレベル引数から無条件に読む(`Compiler.RC2.Loop.applyLoop`
自身の`initial = map RCLoc argIds`による構築)ため、`loopParams`自身の
各エントリは既に`argIds`とここで一致しており、それ以上のチェックは
不要。それ以外の場合: `Compiler.RC2.Loop`自身の`nativeArgType`
(この再利用のため`export`化した)を、ループ持ち回りパラメータだけで
なく全てのトップレベルパラメータについて問う。

### `returnEligibility` / `tailValueReps`

`tailValueReps`は本体の全ての真の(`RLoopContinue`ではない)末尾位置
の値を巡り、既にネイティブと分かっている全てのローカルの
`SortedMap Int Rep`を持ち回る(`paramEligibility`自身の結果からシード
されるので、適格なパラメータの裸の末尾returnもネイティブとしてカウ
ントされる -- `RLet`/`RLoop`自身の束縛を通過するにつれさらに拡張
される)。裸の`RV`/`ROp`/`RPrimVal`は自身のRepを直接読み取る; 呼び出し、
クロージャ、コンストラクタ、extprim、消去、クラッシュはコンテキスト
に関係なく*決して*ネイティブにならない(これがまさに、純粋な委譲
チェーンを非適格にしている理由である)。`returnEligibility`は、
*全ての*そのような末尾値が同じ`ty`に一致する場合にのみ`Just ty`と
なる。

### 検証結果

既存のテスト/ベンチマークスイートに対して確認済み:

- `Main.fib`(`tests/BenchFib.idr`) -> `params=[Int] ret=Int` -- この
  取り組み全体の存在理由である、看板の非末尾再帰ターゲット。
- `Main.sumTo`(`tests/BenchLoop.idr`) -> `params=[Int, Int] ret=Int`、
  `Compiler.RC2.Loop`自身の`RLoop`決定から正しく読み取られている。
- `Main.countDown`/`Main.collatzLike`(`tests/Test9SelfTailLoop.idr`) ->
  正しい*混在*適格性(1つがネイティブ、1つがBoxed)が同じ関数の中に
  ある。
- `Main.swapLoop`、および`Compiler.RC2.MutualLoop`が生成した全ての
  メンバー別wrapper(`Test9SelfTailLoop.idr`の
  `Main.isEvenM`/`isOddM`/`stepA`/`stepB`) -> 正しく何も適格ではない
  (自分自身のパラメータを`ROp`/`RCmpCase`で使うことが一切ない --
  wrapper自身の本体はマージ関数への転送呼び出しでしかない)。

### Stage 3自身の計画を変えた発見

`MutualLoop`自身の*マージ*関数(`{rc2_mutualLoop:N}`、上記のメンバー
別wrapperとは対照的)は、グループのある1メンバーがネイティブとして
読む共有スロットについて、それとは*別の*、より小さいアリティの
メンバーが単に`RCNull`しか供給していない場合でも実際に適格性を示す
**ことがある** -- `Test9SelfTailLoop.idr`自身の`stepA`/`stepB`グループ
に対して直接確認済み(`{rc2_mutualLoop:0}: params=["1:Boxed",
"2:Boxed", "3:Int", "4:Int"]`)。これはまさに、`Compiler.RC2.Loop`
自身のネイティブshadow昇格の間に既に2回の実クラッシュを引き起こした
のと*同じ*形状である(`doc/loop-conversion.md`の「発見されたバグ」#4
参照) -- マージ関数自身の*外部*シグネチャにもネイティブworkerを
与えることは、別の境界で同じ危険を再び開くことになる。wrapper側
(何も適格なものがないのでその除外はタダで成り立つ)とは異なり、
マージ関数には**明示的な**除外が必要だった: `Compiler.RC2.DualABI`
自身の`isMutualLoopMerged`(`MutualLoop.idr`自身の`freshName`が生成
する`MN "rc2_mutualLoop" _`という名前パターンに一致させる)がworker
合成をそれについて丸ごとスキップする。

## Stage 3a: worker合成(パラメータのみ) + wrapper書き換え

`synthesizeWorker`は、適格かつ非`MutualLoop`マージの関数それぞれに
ついて、全プログラム規模の`applyDualABI`から呼び出される:

1. 新しいworker名を発行する(`freshName`/`freshId`/`FreshId`、
   `MutualLoop.idr`が既に使っているのと同じ`Ref`で持ち回るカウンター
   のパターン) -- `idris2rc2_worker_`に、*元の*関数自身のマングルされた
   C名(`Compiler.RC2.Emit`自身の`cName`、この再利用のため今や
   `export`化された -- wrapper自身の変更されないC名が既に使っている
   のと全く同じマングリング)を加え、さらに曖昧さ回避用のカウンタを
   付ける形である。例えば`Main.fib`自身のworkerは
   `idris2rc2_worker_Main_fib_0`になる -- *生成されたもの*であること
   (このプロジェクト自身が確立した、ランタイムが所有する全てのC
   シンボルに対する`idris2rc2_`プレフィックス規約に合致する)と、
   *この特定の元の関数自身のworkerであることが目に見える*ことの両方
   が、一目でわかるよう意図的に作られている -- 元々の不透明な
   `rc2_dualABI_N`というグローバルカウンタとは対照的である。
2. `workerArgs`: 各パラメータを、適格な位置では`RNative ty`に、それ
   以外では`RBoxed`に昇格させる -- **元のパラメータ自身のidをそのまま
   再利用し、リネームは一切不要**。これは`Compiler.RC2.Loop`自身の
   shadow-idトリックに対する本物の単純化である: あちらのメカニズムは
   *新規の*idを必要とした、なぜなら*同じ*関数の中で*既存の*Cパラメー
   タの上に新しい表現を後付けしていたからである(既に
   `IDRIS2RC2_Value *`として宣言済みの名前の下に`int64_t var_p`を
   もう一度宣言するのは、C言語の再宣言エラーになる)。workerは**新規の**
   C関数である -- そのidの下に衝突する既存の宣言は存在しないので、
   元のidをそのまま、新しい(ネイティブな)型で、worker自身のシグネ
   チャの中で直接再宣言できる。
3. `workerBody`: 元の本体そのまま、ただし昇格されたパラメータの
   もはや古くなった所有権記録を`Compiler.RC2.Loop`自身の
   `stripOwnership`(今回`export`化)で取り除いたもの --
   *元の*パラメータid(ステップ2でリネームが不要だったので、リネーム
   済みshadow集合ではない)に対して直接呼び出す。`stripOwnership`
   自身の安全性の論拠(「剥奪対象のidが値として読まれる箇所は、この
   時点で既に一貫してネイティブである」)は、`Compiler.RC2.Loop`自身の
   用途とまったく同じ形でここでも成り立つ -- その自身のdocコメントを
   両方の呼び出しサイトを説明するよう更新済み。
4. `workerDef`: `MkRCFun workerArgs retRep workerBody` -- **`retRep`は
   元の関数から変更されずそのまま渡される**(今日時点では常に
   `RBoxed`)、`returnEligibility`が何を見つけていようと決して昇格
   しない。これはStage 3a自身の意図的なスコープの制限である --
   理由は下記「ステータス」参照。
5. `wrapperBody`: workerへの単一の`RAppNameRep`呼び出し、元のパラ
   メータごとに1つの引数、worker自身が決定した位置ごとのRepで表現
   される。
6. `wrapperDef`: `MkRCFun args retRep wrapperBody` -- **変更なし**の
   元のシグネチャとid、なので他のプログラム中の全ての既存呼び出し元
   は変更ゼロで引き続き動作する。

### エミッション(`Compiler.RC2.Emit`)

Stage 3aが動くCコードを出すために両方とも必要な、2つの変更(苦労して
確認済み -- 下記「発見されたバグ」参照):

- **`createCFunctions`**(関数自身のトップレベルC宣言)が、自身の
  パラメータリストについて`Rep`を意識するようになった: 各パラメータ
  自身のC型は、その`Rep`(`RNative`/`RInlineNative`には`nativeCType
  ty`、`RBoxed`には`IDRIS2RC2_Value *`)から来るようになった(以前は
  常に後者)。`RepMap`(全ての*使用*サイトが参照する、「どのローカル
  がどの`Rep`を持つか」の逐次テーブル)は、空から始まるのではなく、
  関数自身のパラメータで前もってシードされるようになった -- これが
  ないと、ネイティブなパラメータ自身の本体内での*読み取り*は、C宣言
  自体は既に正しくネイティブであるにもかかわらず、Boxedとしてレンダ
  リングされてしまう(`repOfLocal`自身の、何も登録されていない時の
  デフォルト)。`MaxExtractFunArgs`を超えるパラメータを必要とし、
  かつ少なくとも1つがネイティブであるworkerは、現時点では明示的な
  `InternalError`である(下記の`RAppNameRep`自身のエミッション側の
  制限と一致 -- 「ステータス」参照)。
- **`emitRC`の新しい`RAppNameRep`ケース**: 各引数を自身の`Rep`ごとに
  レンダリングし(`tryEmitLoopContinue`自身の確立された位置ごとの
  パターンをミラーする)、workerを直接呼び出し、結果を`retRep`ごとに
  扱う -- 今のところ`RBoxed`だけが実装されている(それ以外は
  `InternalError`)、末尾位置でない場合はトランポリンされ(通常の
  `RAppName`自身の挙動と完全に一致)、末尾位置ではそのまま返される。

  **通常の`RAppName`とは異なり、末尾位置でのクロージャ経由の遅延を
  *しない*ことがなぜここでは安全なのか**: `tryBuildClosureInto`は
  `RAppNameRep`を一切捕捉しない(クロージャの引数スロットはネイティブ
  値を保持できないので、この呼び出しは末尾位置であろうとなかろうと
  常に本物の、即座のC呼び出しとしてレンダリングされる)。Stage 3a自身
  の、このノードの唯一の生成元 -- wrapperが自分自身の、新しく合成
  されたworkerを呼び出す -- についてはこれは証明可能に安全である:
  それは常にちょうど1ホップであり(wrapperは他に何も呼ばない)、
  境界のない再帰チェーンの一部になることは決してないので、通常の
  クロージャ遅延/トランポリンの手順をここでスキップしても、以前から
  可能ではなかった箇所に境界のないCスタック増大を持ち込むことは
  あり得ない。**この安全性の論拠はStage 3a自身の狭い用途に特有の
  もの**(固定トポロジー、単一ホップの委譲)であり、Stage 4が
  プログラム全体にわたる*任意の*呼び出しサイトの書き換えを始める前に
  再検討が必要である -- 下記「Stage 4に向けた未解決の設計課題」参照。

## Stage 3b: ネイティブ戻り値

`returnEligibility`(Stage 2)が何かを見つけた場合に、worker自身の
`retRep`を`RNative`に昇格させる(常に`RBoxed`のままにしていたのを
やめる)。`synthesizeWorker`は`retEligible : Maybe PrimType`を、
wrapper自身の`wrapperRetRep`(元の関数の`retRep`のまま、変更なし)
とは別に受け取るようになった(`Compiler.RC2.DualABI`自身の更新された
docコメント参照)。`applyDualABI`自身の「そもそもworkerを作るべきか」
の判定は「適格なパラメータが1つ以上」から「適格なパラメータ*または*
適格な戻り値が1つでもあれば」に広がった -- 適格なパラメータがゼロで
戻り値だけがネイティブ適格な関数(例えば昇格すべき数値パラメータを
持たない、閉じた計算)という、狭いが実在するケースもこれでカバーされ
るようになった。`isMutualLoopMerged`自身の一括除外は、戻り値側も既に
タダでカバーしている -- どちらが適格であってもマージ関数に対しては
worker合成自体を丸ごとスキップするため。

Stage 3aの後に、それ自身の段階としてこれを着地させたのは、まさに
`Compiler.RC2.Emit`自身の`Sink`/`SinkReturn`機構に触れる必要があった
から -- Stage 3aをパラメータのみにスコープを絞った際に「そのモジュール
の中でも特にトラフィックの高いコードへの、比較的リスクの高い変更」と
名指しされていた箇所そのものである。

### 設計: `Sink`へのフィールド追加1つ、ディスパッチ地点1箇所

実際の変更は、リスク評価が示唆していたよりも小さく済んだ。
`Emit.idr`自身の制御フローが既にどれだけ一点集中していたかによる:
枝分かれする構文(`RCmpCase`/`RConCase`/`RConstCase`/`RLoop`)は既に
全て、それぞれ自身の枝へ*同じ*`Sink`を再帰的な`emitInto`呼び出しで
渡しており、その先は本物の末尾式を扱う唯一の共有フォールバック地点
まで一直線につながっている。よって:

- **`Sink`自身の`SinkReturn`コンストラクタに`Rep`フィールドを追加**
  (`SinkReturn Rep`、以前はペイロードなしの`SinkReturn`) -- 囲む
  関数自身の`retRep`を、`createCFunctions`が一度だけ渡す
  (`emitInto EmptyFC (SinkReturn retRep) InTailPosition body`、以前は
  裸の`SinkReturn`だった)。
- **`resolveSink`/`finalizeSink`/`chainsWithElse`/`buildClosureIntoSink`**
  は*ロジック*の変更が一切不要で、新フィールドを受け入れるようパター
  ンを広げるだけで済んだ(`SinkReturn _`) -- これらの挙動はいずれも、
  戻り値がどの`Rep`を運んでいるかには依存せず、それが変数への代入で
  はなく`return`であるという事実にのみ依存しているため。
- **`emitInto`自身の唯一のフォールバック枝**(`RV`/`ROp`/`RPrimVal`
  等、あらゆる本物の末尾式が最終的に行き着く唯一の場所)だけが実際に
  そのRepを参照する: `SinkReturn (RNative ty)`/`SinkReturn
  (RInlineNative ty)`は、通常の`emitRC`→`finalizeSink`の組み合わせで
  はなく、新設の`emitNativeReturn`へ回される; それ以外の`Sink`は一切
  影響を受けない。

枝分かれする構文がいずれも既に自身に渡された同じ`Sink`値をそのまま
再度渡しているだけなので、このフォールバック地点1箇所を直すだけで、
ループ自身の出口値や、任意にネストした`if`/`switch`連鎖の内側から
返される値までもがネイティブにレンダリングされるようになる --
`emitCmpCaseInto`/`emitConCaseInto`/`emitConstCaseInto`/`emitLoopInto`/
`branchBody`自身には一切変更が要らない。`Main.sumTo`(ループ持ち回りの
ネイティブパラメータ*と*ネイティブ戻り値が両方ある)は、まさにこの
経路を行使する: ループ自身の出口(`if (tmp_3 == 0) { return var_4; }`)
は、`Main.fib`自身の(ループを伴わない)末尾位置とまったく同じ
フォールバック枝を通ってレンダリングされる。

### `emitNativeReturn`: 「`return`の後には文の位置がない」問題

`declareNative`(`RLet`自身のネイティブな束縛)は既にこれとよく似た
問題を解決していた: `emitNativeValue`自身の未処理のBoxedオペランド
drop(その自身のdocコメント参照)は、その値を読む文の*後に*実行しな
ければならず、決して前ではいけない -- しかし`RLet`にとって「後」は
簡単で、同じブロック内に常に次の文があるからだ。`return`にはそのよう
な「後」が存在しない -- 制御は即座に関数を離れるので、裸の
`return valStr;`の後にdropを置いても、それは決して実行されない。

`emitNativeReturn`は`declareNative`自身の2段階の形(値を確定させて
から、*その後に*未処理のdropを処理する)をミラーするが、実際に順序
調整すべきdropが存在する場合にのみ、余分なスクラッチ変数のコストを
払う:

```idris
emitNativeReturn fc ty value = do
    (valStr, pending) <- emitNativeValue ty value
    case pending of
         [] => emit fc "return \{valStr};"
         _  => do
             tmp <- getNewVarThatWillNotBeFreedAtEndOfBlock
             emit fc "\{nativeCType ty} \{tmp} = \{valStr};"
             removeVars $ map varName pending
             emit fc "return \{tmp};"
```

このスクラッチ変数は、本物の`RCLoc` idが持つ`var_N`という番号空間で
はなく、既存の`tmp_N`命名(`getNewVarThatWillNotBeFreedAtEndOfBlock`、
`makeClosure`が同じ「自分自身を宣言した文より後まで生き残らなければ
ならない」というニーズのために既に使っている)を再利用する --
`declareNative`が`var_N`を使えるのは、それが本物の、木で番号付けされた
ローカルを宣言しているからであり、こちらは`RCExp`の木に自分自身のid
を持たない合成の、エミッション専用の一時変数なので、ここで`var_N`を
再利用すると本物のローカルと衝突する危険がある。

`Main.fib`自身のworkerは、自明でない経路(両方の再帰呼び出し自身の
Boxedな結果を、加算がそれらを読んだ*後に*dropする必要がある)の
典型例である:

```c
int64_t tmp_8 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));
idris2rc2_drop(var_3);
idris2rc2_drop(var_5);
return tmp_8;
```

一方、その基底ケース(パラメータをそのまま直接returnする、`if (n < 2)
then n else ...`)は自明な経路である -- 未処理のdropが一切ないので、
スクラッチ変数も不要:

```c
if (tmp_7 == UINT8_C(1)) {
    idris2rc2_drop(var_1);
    return var_0;
}
```

### `emitNativeValue`に裸の`RV`ケースを追加

`emitNativeValue`はこれまで、Phase 1自身のANF正規化が`RLet`の末尾
として渡し得るもの -- `ROp`、`RPrimVal`、あるいは透過的なラッパー
ノード(`RLet`/`RDup`/`RDrop`/`RFree`/`RReleaseReuse`)のいずれか --
だけを処理すればよく、裸の`RV`を処理する必要は一度もなかった、
「この別のローカルをそのままコピーする」という形の`RLet`束縛はその
経路では発生しないからである。しかし`Compiler.RC2.DualABI`自身の
`tailValueReps`(Stage 2)は、裸の末尾位置の`RV`(パラメータ、あるいは
既にネイティブな中間値がそのまま返される場合)を常にネイティブとして
カウントすることを許していた -- Stage 3bは、このケースがエミッション
時に実際に到達する最初のもの(上記の`Main.fib`自身の`if n < 2 then n
else ...`基底ケース)である。直接以下を追加した:

```idris
emitNativeValue ty (RV fc v) = do
    valStr <- rcVarToNativeC ty v
    pure (valStr, [])
```

未処理のdropは一切ない -- `ROp`自身のオペランドとは異なり、ここでの
`v`は構築上既にネイティブと分かっている(`tailValueReps`自身のシード
がそれを保証している)ので、後始末すべきBoxedな読み取りが存在しない。

### `RAppNameRep`自身のネイティブ`retRep`ケース

worker自身の戻り値がネイティブに昇格されたことで、*wrapper*からその
workerへの呼び出し(`RAppNameRep`、Stage 3a)も、非`RBoxed`な`retRep`
を本当に持ち得るようになった -- 以前は`InternalError`(「まだ未実装」)
だった。この関数の他のすべてのケースと同様、`emitRC`自身のこのノード
に対する契約は「常にBoxedな式文字列をレンダリングする」であり --
`RBoxed`は以前とまったく同じに振る舞う(末尾位置以外ではトランポリン、
末尾位置では裸のまま); `RNative`/`RInlineNative`は`call`自身が既に
worker自身の生のネイティブ結果であることを意味するので、
`nativeMk ty call`で直接box化する、末尾位置かどうかに関わらず無条件
に -- ネイティブな値がそれ自身「まだ解決を待つトランポリン」になる
ことは決してあり得ない(それはBoxed表現にのみ存在する概念だ:
未解決の継続をエンコードし得るタグ付きヒープポインタ)ので、どちら
にせよ遅延させるべきものは何もない。`Main.fib`自身のwrapperが具体例
である:

```c
IDRIS2RC2_Value *Main_fib(IDRIS2RC2_Value * var_0)
{
    return idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(idris2rc2_to_i64(var_0)));
}
```

この方向(ネイティブなworker自身の結果をBoxedとしてレンダリングし、
wrapper自身の常にBoxedな末尾値にする)だけが実装されている -- 呼び出し
元が`RAppNameRep`自身の結果を(box化をスキップして)*ネイティブ*の
ままレンダリングしたい場合はStage 4自身の課題である: Stage 3bにおける
このノードの唯一の生成元は依然として`Compiler.RC2.DualABI`自身の
wrapper本体であり、常に`SinkReturn RBoxed`へ供給している。

### `createCFunctions`自身の戻り値型宣言

残る1点: C関数宣言そのもの(`IDRIS2RC2_Value *\{cName ...}`、無条件)
が、`declareParam`自身の既存の引数ごとのロジックをミラーする形で、
`retRep`から自身の戻り値型を導出するようになった:

```idris
let retTypeStr : String = case retRep of
                                RBoxed => "IDRIS2RC2_Value *"
                                RNative ty => nativeCType ty ++ " "
                                RInlineNative ty => nativeCType ty ++ " "
let fn = "\{retTypeStr}\{cName !(getFullName n)}" ++ ...
```

`Main.fib`自身のworkerは`int64_t idris2rc2_worker_Main_fib_0(int64_t var_0);`
という前方宣言になる -- 生成されたCを直接読んで確認済み、他のあらゆる
段階と同じ検証の規律に従っている。

## Stage 4: 呼び出しサイトの書き換え

実際のパフォーマンス向上が実現される段階である。(3a/3bとは異なり)
これ以上分割せず、1つの統合されたステージとして着地させた -- 「呼び
出しを書き換える」半分は既に検証済みのエミッション機構
(`emitAppNameRepInto`は既にネイティブな結果を必要に応じてbox化する)
を再利用するだけで、実質的に新たなリスクはない一方、「囲む`RLet`を
昇格させる」半分こそが書き換えを実際に報われるものにしている。前半
だけを行えば、あらゆる呼び出しが自身の結果をbox化しては直後に再び
unbox化するだけに終わり、専用の段階を割くに値しない、ぱっとしない
効果にしかならなかったはずである。

### 適用範囲: 非末尾位置の呼び出しのみ、恒久的に

直接的で飽和した**非末尾位置**の呼び出しだけが、自身の呼び出し先の
workerへとリダイレクトされる。workerを持つ関数への末尾位置の呼び出し
は*意図的かつ恒久的な*スコープ境界であり、後続の段階で対応するもの
ではない: これらは現在`tryBuildClosureInto`自身のクロージャ遅延
(box化されトランポリンされる値として返し、*呼び出し元自身のさらに
呼び出し元*が後で解決できるようにする -- `Compiler.RC2.Loop`/
`Compiler.RC2.MutualLoop`が既に`goto`へ変換する自己/相互再帰的な形
ではない、深さが未知の末尾呼び出し連鎖についてCスタックの増大を抑
える)によってレンダリングされている。このような呼び出しを直接的で
遅延されない`RAppNameRep`呼び出しに書き換えてしまうと、その無制限の
増大を再び持ち込みかねない上、*どの*末尾位置の呼び出しサイトをこの
方法で安全に書き換えられるかを判別するには本物のプロシージャ間解析
が必要になる -- まさに、この取り組み全体がこれまで避け続けてきた
プログラム全体規模の不動点そのものである(Stage 2で`returnEligibility`
が既に*純粋な*末尾呼び出し委譲を追いかけるのではなく対象外としている
理由と同じである)。

### workerテーブル

`workerTable`は、「どの関数がworkerを得たか、そしてその
`(workerName, argReps, retRep)`自身は何か」を、`applyDualABI`実行後
のdefs一覧を、`synthesizeWorker`が常に生成するwrapper自身の形 --
`MkRCFun _ _ (RAppNameRep _ workerName argReps retRep _ _)`、それ以外
の本体は一切持たない -- に一致するものとして走査することで復元する。
`applyDualABI`自身から別途テーブルを引き回す必要は一切ない。

### 書き換え: `applyCallSiteRewriteBody`

全ての定義自身の本体(wrapper、worker、あるいは手つかずの関数 -- 3つ
のうちどれであるかをここで知る必要は一切なく、全く同じロジックで
書き換えられる)を歩き、既知のRepのローカル変数を保持する
`SortedMap Int Rep`(`paramEligibility`/`tailValueReps`が既に使って
いるのと同じシード付け/拡張方法)と、現在地点が本当に*関数全体自身
の*末尾位置であるかどうかを追跡する`Bool`を引き回す -- `True`になる
のはトップレベルの入口だけであり、`RLet`自身の`body`、あらゆる分岐
構造自身の各分岐、あらゆるラッパーノード自身の`cont`はどこも変更せ
ずそのままスレッドする。

唯一本当に注意が必要な点: `RLet`自身の*value*は、一見そう見えるよう
なフラットな末端(`ROp`/`RAppName`/`RCon`等)とは限らない。Phase 1
自身のANF正規化は、呼び出しの*引数*式に対しては、外側の`RLet`自身の
valueの**内側**にさらに`RLet`をネストさせる --

```
let v3 = (let v4 = n - 1 in fib v4) in
let v5 = (let v6 = n - 2 in fib v6) in
v3 + v5
```

-- そのため実際の呼び出しは、`value`自身として直接現れることは一切
なく、さらなる`RLet`の連鎖の中に任意の深さで埋まっていることがある。
`RLet`節はこれを、まず(非末尾モードで)`value`自身へ再帰することで
処理する(そうすることで、*自身の*究極の末尾に何らかの`RAppName`が
座っていれば -- この同じ関数自身の総称ケース、実際に何かを書き換え
る唯一の節を通じて到達する -- それも書き換えられる)。その後、書き
換え済みの`value1`自身の`ultimateTail`(同じネストした`RLet`の形を
剥いていく)を調べることで、*外側*の`RLet`自身(上の例で言えば
`v4`/`v6`ではなく`v3`、`v5`)が昇格候補かどうかを判定する。

`postDropFor`は、書き換えられた引数のうちどれが明示的なdropを必要と
するかを判定するために、それ自身の生存解析を一切必要としない: 置き
換えられる*元の*(まだ`RAppName`のままの)呼び出しについて、
`Compiler.RC2.RC`自身の`annotate`が既に、Boxedな引数を呼び出しへ渡す
ことはちょうど1個の参照を消費すると(その引数自身のローカルがこの後
もまだ必要なら事前にdupしつつ)判断済みである -- 代わりにそれを
ネイティブに読み、ここで直接dropすることは、正確に同じ正味のコスト
を支払うことになるので、`annotate`が呼び出しサイトの周りに既に整え
ていたものは、どちらの方法でも変わらず正しく釣り合ったままになる。

### 昇格: `nativePromotionFor`

`Compiler.RC2.Loop`自身の`nativeArgTypes`(今や`nativeArgType`と並んで
`export`化された)をそのまま再利用する -- 関数全体自身のトップレベル
パラメータについて既に問うているのと同じ問いを、代わりに`RLet`束縛
されたworker呼び出しの結果について問うだけである: このletの残りの
自身のスコープは、それをworker自身の`retRep`において一貫してネイテ
ィブコンテキストのオペランドとして読んでいるか? 見つかった場合、
`stripOwnership`(3度目の再利用であり、ここでもidのリネームは不要
-- 既に宣言済みのC変数に後付けするのではなく、新しいRLet束縛である
ため)が、`annotate`がかつて通常のBoxedローカルだと想定していた時代
遅れのBoxed生存期間の帳簿付けを取り除く。同じローカルの*他の*、依然
としてBoxedコンテキストでの利用(例えばコンストラクタのフィールドへ
格納される場合)は、昇格の有無にかかわらずそのまま動作し続ける --
`rcVarToBoxedC`自身のオンデマンドな再box化によるもので、この呼び出し
が*かつて*生成していたものを共有する代わりに新規に確保する(Idris
レベルのプログラムからは一切観測不可能である -- スカラーには観測
可能なアイデンティティがないため)。

`fib`自身のworkerが、その前後の具体例である:

```c
// Stage 4適用前
IDRIS2RC2_Value * var_3 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_4)));
IDRIS2RC2_Value * var_5 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_6)));
int64_t tmp_9 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));

// Stage 4適用後
int64_t var_3 = idris2rc2_worker_Main_fib_0(var_4);
int64_t var_5 = idris2rc2_worker_Main_fib_0(var_6);
return (var_3 + var_5);
```

再帰呼び出しのどちらについても、その引数・結果いずれについてもbox化
・unbox化・dup/dropは一切ない -- 計算全体がworker自身の入口から自身
の`return`まで、`int64_t`のまま保たれる。

## 発見されたバグと修正

1. **Stage 3aが最初に着地した時点で`createCFunctions`がまだ
   `Rep`を意識していなかった。** worker(`BenchFib.idr`自身の`fib`)の
   最初のエンドツーエンドビルドは*生成されたCのコンパイル*に失敗
   した: wrapperは正しく引数をunbox化し、生の`int64_t`でworkerを
   呼び出したが、worker自身のC宣言は依然`IDRIS2RC2_Value * var_0`の
   ままだった(Stage 1は意図的にこちら側を`Rep`対応にすることを先送り
   していた -- 当時の自身のモジュールノート「ここで最初に非`RBoxed`
   な値を作る何かと一緒に構築する」参照)。`createCFunctions`が各
   パラメータ自身の`Rep`をC宣言のために参照するようにし、関数自身の
   パラメータで`RepMap`を前もってシードするようにして修正した
   (上記「エミッション」参照) -- これは常に計画通りだったが、実際に
   それを行使・検証できる何かが現れるまで意図的に構築していなかった、
   このプロジェクト自身の確立された規律に従ったもの(`doc/
   loop-conversion.md`自身の「発見されたバグ」一覧の大半は、この規律
   が緩んだ時に何が起きるかの歴史である)。
2. **`declareLoopParam`自身のNULLガードが、`initVal`が既にネイティブ
   であってさえ無条件に適用されていた。** このプロジェクト自身の
   全面的な検証スイープ(refc-suiteだけではない -- まさにこの理由で、
   その広範なスイープが標準の方法論の一部になっている)で発見された。
   `Test1Basics.idr`自身の`Main.loop`と`Test9SelfTailLoop.idr`の
   `countDown`/`collatzLike`で、合成されたworkerの内部で
   `-Wall`クリーンなビルドが`comparison between pointer and integer`
   で失敗した。根本原因: 自己末尾再帰(既に`Compiler.RC2.Loop`によって
   `RLoop`でラップされ、`Compiler.RC2.Loop`自身の`declareLoopParam`が
   `MutualLoop`自身の`RCNull`パディングに対してループ突入時のunbox化
   を無条件にガードしている -- `doc/loop-conversion.md`の「発見された
   バグ」#4参照)*かつ*デュアルABI適格な関数は、`Compiler.RC2.Loop`
   自身の`declareLoopParam`がそれを処理する時点で、既に`RNative`
   (`RBoxed`ではない)なトップレベルパラメータを持つworkerになる
   (`Compiler.RC2.Emit`自身の`createCFunctions`が、ループ自身の宣言が
   走るより前に、そのようにそれを登録する)。`declareLoopParam`自身の
   NULLガードは、「`initVal`は常に、囲む関数自身のトップレベルの
   (常にBoxedな)引数の1つである」という前提の下で全面的に書かれて
   おり、それ自身が既にネイティブであることは決してない、と想定して
   いた; `Compiler.RC2.DualABI`自身のworker合成は、まさにその前提を
   壊すケースである。`rcVarToNativeC`自身は既にこれを正しく処理して
   いた(既にネイティブなローカルはそのまま読み戻され、変換は一切
   出力されない) -- しかしそれを包む*ガード*
   (`(initValName == NULL) ? 0 : (...)`)は、`initValName`が裸の
   `int64_t`であって、ポインタではない場合に型検査を通らない。
   `repOfLocal initVal`を*先に*チェックすることで修正した: ガード
   (とそのすぐ後のBoxed値のdrop)は、`initVal`が本当にまだ`RBoxed`で
   ある場合にのみ適用される; 既にネイティブな`initVal`は代わりに、
   ガードなしの普通の宣言を得る。再検証: 以前失敗していた4ファイル
   全てが再ビルドでき、本物の`idris2 --cg refc`に対して実行しても
   引き続きバイト単位で一致する; refc-suite全体(19/19)も影響なし。

Stage 3b(ネイティブ戻り値)はそれ自身の新規バグを1件も見つけなかった
-- 実装前に行った設計レビュー(`emitInto`自身の一点集中ディスパッチ
構造、そして`emitNativeReturn`が必要とする正確な「確定させてから
drop、それから return」という順序を、コードを書く前に洗い出したこと)
が、そうでなければ3件目のバグとしてここに載っていたであろうものを
未然に防いだと考えられる。最初のビルドがそのまま成功し、下記の全面
的な検証スイープ(上記バグ#2に最も近い形の、`Main.sumTo`自身のループ
+ネイティブ戻り値の組み合わせを含む)も、一切の修正なしに通過した。

3. **`RAppNameRep`は、ネイティブに読んだBoxed由来の引数を全て
   リークしていた。** Stage 4(呼び出しサイトの書き換え)を設計して
   いる最中に発見された: *さらに多くの*呼び出しサイトをBoxed値の
   ネイティブ読み取りへ書き換える前に、既存のStage 3a wrapper --
   昇格されたパラメータの全てについて既にまさにそれを行っていた --
   を、単に信頼するのではなく実際に経験的に再検証した。
   `rcVarToNativeC`(`RAppNameRep`自身の引数レンダリングが
   `RNative`/`RInlineNative`な位置のいずれについても使うunbox化
   アクセサ)は、それ自身では一切dup/dropを行わない(自身のドキュメ
   ントコメント参照) -- それは値を*読む*だけであり、元のBoxed参照を
   生きたまま残す。`ROp`/`RCmpCase`は自身の`annotate`が決定する
   `postDrop`フィールドを通じて既にこれを正しく処理しているが、
   `RAppNameRep`にはそのようなフィールドが一切なく、しかも --
   `ROp`とは異なり -- `Compiler.RC2.DualABI`自身のworker/wrapper合成
   はそもそも`annotate`の所有権解析を一切通らない(`RAppNameRep`
   ノードを直接構築するのは、`annotate`が定義全体の処理を既に終えた、
   ずっと後である)ため、このdropが必要だと判断するものが誰もいなか
   った。`Main.fib`自身のwrapperは、既存の検証スイープでこれを一度
   も表面化させなかった -- `fib 30`の間に昇格される値は全て
   small-intキャッシュの範囲(`[0,100)`、不滅の`refCount ==
   IDRIS2RC2_REFCOUNT_MAX`な共有シングルトンに支えられている -- その
   1つに対する`idris2rc2_drop`は無条件にno-opなので、*欠落した*drop
   は正しいものと見分けがつかず沈黙する)に収まっていたためである
   -- 以前このプロジェクトを一度噛んだのと全く同じ「no-opに隠れる」
   形(32bit以下のポインタタグ付け)である。合成的な最悪ケース
   (`tests/Test11DualABILeak.idr`、昇格されるパラメータ自身の値を
   意図的にキャッシュ範囲外へ押し出したデュアルABI適格な関数)に対
   する`valgrind --leak-check=full`で確認した: 200万回の呼び出しに
   対して`31,999,984 bytes in 1,999,999 blocks definitely lost` --
   実質的に*呼び出し1回につき*1個のリークしたアロケーションである。
   `RAppNameRep`自身に`postDrop : List RCLocal`フィールドを与え、
   `ROp`自身のものを正確に踏襲することで修正した:
   `Compiler.RC2.DualABI`自身の`synthesizeWorker`がこれをただで埋める
   (それは正確に、無関係な目的で既に`eligible`として計算済みの、
   wrapper自身の昇格されたパラメータidそのものである)。
   `Compiler.RC2.Emit`には専用の`emitAppNameRepInto`が新設された
   (`RAppNameRep`は`emitRC`自身の「常にBoxedな文字列をレンダリング
   し、保留中のdrop一覧の余地がない」ディスパッチから、`emitInto`
   自身のノードごとのディスパッチ -- `RCmpCase`/`RConCase`等と並ぶ
   -- へ移された)。これは呼び出し自身の値が自身の文へ組み込まれた
   後に`postDrop`を消化する -- `SinkReturn`ターゲットについては
   `emitNativeReturn`自身の「まず一時変数へ確定させる」トリックを
   再利用し(`return`の*後*には、dropが収まる文の位置が一切存在しな
   いため)、`SinkVar`ターゲット(こちらは常に1つ持つ)については
   単純な「確定させてからdrop」とする。再検証: 同じ合成ケースに対
   する`valgrind`は今や`definitely lost: 0 bytes in 0 blocks`を報告
   する(`total heap usage: 14,000,124 allocs, 14,000,024 frees` --
   100ブロックの差は正確に不滅のsmall-intキャッシュ分であり、リーク
   ではない); refc-suite全体(19/19)と`tests/Test*.idr`/`Bench*.idr`
   一式全体を、本物の`idris2 --cg refc`に対して再度バイト単位で突き
   合わせたが、影響なし。
4. **Stage 4の最初の試みは、`fib`自身の再帰呼び出しを実際には一切
   書き換えていなかった -- しかも沈黙したまま。** 最初の動作する
   ビルドは正しくコンパイル・実行できた(`fib 30`は依然`832040`)
   ため、これは見落としやすかった -- 生成されたCを直接読むこと
   (このプロジェクト自身の標準的な規律)によってのみ、
   `idris2rc2_worker_Main_fib_0`自身の本体が依然として(自分自身では
   なく)`Main_fib`(wrapper)を呼んでいることが判明した。根本原因:
   `applyCallSiteRewriteBody`の最初のバージョンは、`RLet`自身の
   *value*として直接座っている呼び出ししか認識せず、それ以外の経路
   で到達した裸の`RAppName`は「関数全体自身の末尾位置に違いない、
   そのままにせよ」という前提を置いていた -- これは手で試したあら
   ゆる形については成り立っていたが、`fib(n - 1)`については成り立
   たなかった: Phase 1自身のANF正規化は、呼び出しの*引数*式に対して
   は外側の`RLet`自身のvalueの**内側**にさらに`RLet`をネストさせる
   (`let v3 = (let v4 = n - 1 in fib v4) in ...`)ため、呼び出し自身
   は一度も`RLet`自身のvalueとして直接現れることがなく、走査自身の
   「末尾位置に違いない」というフォールバックがそれを飲み込んで
   いた。明示的な`inTail : Bool`を走査全体に引き回すことで修正した
   (`Compiler.RC2.Emit`自身の`TailPositionStatus`を踏まえた形) --
   `True`になるのは定義自身のトップレベルの入口のみで、末尾性を変え
   ないあらゆる構造を通じてそのままスレッドされ、`RLet`自身の
   `value`へ下る際は*常に*`False`になる -- そのため、裸の`RAppName`
   がそのまま放置される唯一の場所は、`inTail = True`で到達した箇所、
   つまり本当に関数全体自身の末尾位置だけになる; それ以外のどこで
   あっても、それは*何らかの*値計算の連鎖の究極の末尾であり、常に
   安全に書き換えられる。修正された設計については、
   `applyCallSiteRewriteBody`自身の上記のドキュメントコメントを参照。
5. **`nativeArgType`自身の確立された「裸の末尾は常にBoxed」という
   前提が、Stage 4が走る時点では既に陳腐化していた。** 上記バグ#4を
   修正した後でさえ、`fib`自身のworkerは依然として両方の再帰呼び
   出し自身の結果をbox化しては
   (`idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(...))`)、`+`のため
   に即座に再びunbox化していた -- 昇格そのものが一切発火していなか
   った。`Compiler.RC2.Loop`自身の`nativeArgTypes`(昇格の判定にその
   まま再利用される、上記「Stage 4」参照)は、候補変数を読む裸の、
   それ以上`RLet`束縛されていない`ROp`/`RCmpCase`を意図的に数えない
   -- これは*そのパス自身の*呼び出し元(`Compiler.RC2.Loop.applyLoop`、
   常にどの関数自身の戻り値適格性が判定されるより厳密に前に走るため、
   *それが*問う時点では、裸の末尾は本当に常にまだBoxedである)にと
   っては正しい -- しかし`v3 + v5`は`fib`自身のworkerの裸の末尾*その
   もの*であり、Stage 4自身のパイプライン上の位置の時点では、その
   末尾はworker自身の`retRep`が既にそうであるからこそ、既にネイティ
   ブにレンダリングされると分かっている(`Compiler.RC2.Emit`自身の
   `emitNativeReturn`、Stage 3b)。`nativeArgType`を無改造のまま再利用
   したことで、この段階全体が存在する理由そのものである、最も重要な
   単一のケースを沈黙のうちに見逃していた。`nativeArgTypes`/
   `nativeArgType`自身には一切手を触れず(どちらも既に他所で十分検証
   済み -- そこで必要だった変更は、既に`export`化されている
   `nativeArgType`と並んで、集合を返す`nativeArgTypes`を`export`化
   することだけだった)、この1つの追加の形だけを特にチェックする、
   Stage 4スコープの別の`bareTailNativeReads`を追加し、最終的な
   「ちょうど1つの一貫した型」判定の前に`nativeArgTypes`自身の結果と
   和を取ることで修正した。生成されたCを直接読んで確認した:
   `fib`自身のworkerは今や`int64_t var_3 =
   idris2rc2_worker_Main_fib_0(var_4); ...; return (var_3 + var_5);`
   を読む -- 再帰呼び出しのどちらについても、box化・unbox化・
   dup/dropは一切ない。
6. **`MaxExtractFunArgs`(8個)を超えるトップレベルパラメータを持つ
   デュアルABI適格な関数がコンパイラをクラッシュさせていた。** 実在
   の、外部由来のパッケージ
   ([`idris2-missing-containers`](https://github.com/seagull-kamome/idris2-missing-containers)、
   `BENCHMARKS.md`自身の再計測参照)に対して発見された -- このプロ
   ジェクト自身のテストスイート(これほど広い関数を1つも持たない)
   の何かによってではない -- `idris2 --cg refc -p missing-containers
   -p contrib Main.idr`は`INTERNAL ERROR: [rc2] RAppNameRep: more
   than 8 args not yet supported`で即座に失敗した。根本原因:
   `RAppNameRep`自身のエミッション(`emitAppNameRepInto`と
   `emitNativeValue`自身のケース、上記「Stage 3a」「Stage 4」参照)
   には、通常の常にBoxedな多引数関数自身の`createCFunctions`経路が
   既に持っているような、`MaxExtractFunArgs`を超える引数のための
   `var_arglist[]`形式のbox化された配列抽出のフォールバックが一切
   ない -- パッケージ自身のラムダリフトされた内部ヘルパーのいくつか
   は9〜23個のパラメータ(囲むスコープから捕捉された自由変数)を持ち、
   そのうち少なくとも2つは本当にネイティブ昇格可能なパラメータをその
   中に含んでいたため、これほど広い関数に対してworker(そしてwrapper
   自身がそこへ行う呼び出しについては`RAppNameRep`)が合成されていた
   -- これはStage 3aの時点から存在しており、Stage 4によって持ち込ま
   れたものではない(コンパイラをStage 3a/3bまで遡ってbisectし、
   さらに別途、このブランチ全体が始まった元のデュアルABI導入前の
   コミットについても確認した -- このパッケージに対して実際にテスト
   した途端、全て同一のクラッシュを再現した。このプロジェクト自身の
   スイートは、この形を一度も行使したことがなかったためである)。
   抽出フォールバックを構築するのではなく(実作業であり、これほど
   広い関数は稀にとどまると見込まれる)保守的に修正した:
   `applyDualABI`自身の`synthesizeIfEligible`は、今や
   `MaxExtractFunArgs`を超えるパラメータを持つあらゆる関数を、
   `paramEligibility`/`returnEligibility`が本来どう判定するかにかか
   わらず無条件に、デュアルABI適格性そのものから除外する --
   `isMutualLoopMerged`が既に使っているのと同じ一括除外の形である。
   `MaxExtractFunArgs`自身(`Compiler.RC2.Emit`)は今やこの再利用の
   ために`export`化されており、この2つの上限が誤って乖離することは
   あり得ない。再検証: refc-suite全体(19/19)、
   `tests/Test*.idr`/`Bench*.idr`一式全体を本物の`idris2 --cg refc`
   に対して再度バイト単位で突き合わせ(どれもこれほど広い関数を持た
   ないため、この除外の影響を実際に受けるものは一つもない)、
   `valgrind`も引き続きリークをゼロと報告。**別件として**(デュアル
   ABI自身のバグではなく、環境の問題でもない -- 最初はそう見えたが):
   `idris2-missing-containers`パッケージ自身の`benchmarkHashMap`は、
   `idris2-rc2`と無改造の本家`idris2 --cg refc`の*両方*で実行時に
   クラッシュする(`Unhandled input for Main.case block`)ように見え、
   このブランチがこれまで構築してきた全てのコミットまで遡って
   bisectしても毎回全く同一の失敗が再現した -- しかし本当の原因は、
   後にワークスペース全体をゼロから再構築している最中に判明した、
   単純な誤った作業ディレクトリからコンパイル済みベンチマークバイナ
   リを実行していたことだった(`Main.idr`自身の`benchmarkHashMap`は、
   `openFile`失敗時の`Left`分岐が一切書かれていない状態で
   `test/words`/`test/input_large`をパッケージルート相対パスで開いて
   おり、誤ったcwdはバックエンドやコミットに関わらず一貫してこの
   「unhandled input」クラッシュとして表面化する)。パッケージルート
   から実行すれば、3つのバックエンド(`idris2-rc2`、本物の`idris2
   --cg refc`、Chez上の本物の`idris2`)全てが正しく完走する
   (`BENCHMARKS.md`自身の再計測参照)。

## ステータス

**実装・検証済み**(Stage 1、2、3a、3b、4)。`Main.fib`は、wrapper
(`Main_fib`、変更されないBoxedシグネチャ、他のどこにいる既存の呼び
出し元も無改造のまま動作し続ける)と、本物の再帰処理を完全にネイティ
ブな`int64_t`のまま行うworker(`idris2rc2_worker_Main_fib_0`)に
コンパイルされ、**自身の再帰呼び出しの両方が今やworkerを直接ターゲ
ットにしている** -- この計算のどこにもbox化・unbox化・ヒープ確保・
dup/dropは一切なく、全体がworker自身の入口から自身の`return`まで
`int64_t`のまま保たれる(生成されるCコードはStage 4自身の前後比較
コードサンプルを上記参照)。
正しい結果(`fib 30`について`832040`)を確認済み、リークがないことを
確認済み(`valgrind --leak-check=full`、`tests/BenchFib.idr`、
`tests/BenchLoop.idr`、`tests/BenchChain.idr`、
`tests/Test11DualABILeak.idr`にわたって`definitely lost: 0 bytes`)、
refc-suite全体(19/19)とスモークテスト/ベンチマーク一式全体を本物の
`idris2 --cg refc`に対してバイト単位で再検証済み、そして -- この取り
組み全体で初めて -- **計測された**パフォーマンスの向上: `fib 30`を
直接計測すると(`time`、3回実行それぞれ)、`idris2-rc2`では約0.14秒、
本物の`idris2 --cg refc`では約0.21秒で、この取り組み全体が存在する
理由である看板的な非末尾再帰ケースにおいておよそ**35%高速**である。

末尾位置の呼び出しは恒久的にスコープ外のままである(上記「Stage 4」
の「適用範囲」参照) -- 後続の段階ではなく、Stage 2自身の
`returnEligibility`の「純粋な委譲」除外と同種の、意図的で熟考された
境界である。

## ファイル

- `rc2/src/Compiler/RC2/DualABI.idr` -- `paramEligibility`/
  `returnEligibility`/`tailValueReps`(Stage 2)、`synthesizeWorker`/
  `applyDualABI`/`isMutualLoopMerged`/`FreshId`(Stage 3a+3b:
  `synthesizeWorker`は今や`workerArgs`だけでなく`workerRetRep`も
  `wrapperRetRep`とは独立に昇格する)、`describeEligibility`/
  `dumpDualABI`(`--directive dumpdualabi`デバッグダンプ)、
  `workerTable`/`applyCallSiteRewriteBody`/`applyCallSiteRewrite`/
  `ultimateTail`/`bareTailNativeReads`/`nativePromotionFor`/
  `postDropFor`/`localRepIn`(Stage 4)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCFun`の新しい形、
  `RAppNameRep`(今や`ROp`自身のものを踏襲した`postDrop`フィールドを
  持つ、上記の参照リーク修正で追加)。
- `rc2/src/Compiler/RC2/Loop.idr` -- `Compiler.RC2.DualABI`自身の再利用
  のため`nativeArgType`/`nativeArgTypes`/`stripOwnership`を`export`化;
  `renameRCExp`内の防御的な`RAppNameRep`素通しケース(今や`postDrop`も
  リネームする)。
- `rc2/src/Compiler/RC2/RC.idr` -- `MkRCFun`の新しい形に合わせて更新
  した`normalizeDef`/`annotateDef`; `annotate`内の防御的な
  `RAppNameRep`素通しケース。
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `MkRCFun`の新しい形に合わせ
  て更新(マージ関数と各メンバーのwrapperは共に、このパス自身の設計
  により無条件に常に`RBoxed`のまま)。
- `rc2/src/Compiler/RC2/Emit.idr` -- `createCFunctions`が関数自身の
  戻り値型宣言と各パラメータ自身の宣言/`RepMap`シードの両方について
  `Rep`を意識するようになった; `Sink`自身の`SinkReturn`コンストラクタ
  が`Rep`を運ぶようになった(Stage 3b); 新設の`emitNativeReturn`;
  `emitNativeValue`の新しい裸`RV`ケース(Stage 3b)と新しい
  `RAppNameRep`ケース(Stage 4、昇格された`RLet`自身のネイティブ消費
  レンダリング用); `emitInto`のフォールバック枝がネイティブな
  `SinkReturn`を`emitNativeReturn`へ回すようになった; `RAppNameRep`は
  `emitRC`自身のディスパッチから完全に外され、新設の専用
  `emitAppNameRepInto`(`emitInto`自身のノードごとのディスパッチ、
  `RCmpCase`/`RConCase`等と並ぶ)へ移り、自身の`postDrop`を消化する
  ようになった; `cName`が`Compiler.RC2.DualABI`自身のworker命名での
  再利用のため`export`化された。
- `rc2/src/Compiler/RC2/Pretty.idr` -- `MkRCFun`の新しい`args`/
  `retRep`レンダリング; `RAppNameRep`自身の`callRep`レンダリング(今や
  `postDrop`も含む)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身のパイプライン配線
  (`applyLoop`の後に`applyDualABI`、その後`applyCallSiteRewrite`);
  `--directive dumpdualabi`の配線。
- `rc2/tests/Test11DualABILeak.idr` -- 上記の参照リークバグの回帰
  テスト; 単なるstdout diffだけでなく`valgrind --leak-check=full`で
  検証すること(テストファイル自身のコメント参照)。

## 検証方法

1. ビルド+回帰テストの基準線: `CLAUDE.md`の「Build & test」節を参照
   (`idris2 --build rc2.ipkg`、次に`tests/refc-suite/run.sh`、19/19を期待する)。
2. `--directive dumpdualabi`(上記Stage 2自身の節参照)を任意の候補
   関数に対して使うのが、生成されたCを一切見る前に適格性を確認する
   最速の方法である -- 例えば`grep "Main.fib" out.dualabi`は
   `params=[Int] ret=Int`を示すはず。注意: このダンプは
   *`applyDualABI`実行後*のdefs一覧に対して走る(`RC2.idr`自身の
   パイプライン上の位置)ため -- ある関数について実際にworkerが合成
   された後は、*元の*名前が(設計通り)Boxedなparams/retの薄いwrapper
   を指すようになっているので、そちらも正しく`Boxed`/`Boxed`と表示
   される; 興味深いネイティブ判定の結果は、worker自身がどう構築され
   たかであり、それは生成されたCを直接見て確認する(次のステップ)。
3. `tests/BenchFib.idr`があらゆる段階の標準的なスモークテストである:
   `fib 30`は依然`832040`を印字しなければならない; `grep -n
   "^int64_t idris2rc2_worker_\|
   ^IDRIS2RC2_Value \*idris2rc2_worker_" build/exec/*.c`はworkerが
   実際に合成されたこと、その戻り値がネイティブになったかどうかを
   確認でき、その自身のC本体を直接読むことで、(a)昇格されたパラメ
   ータ/戻り値が自身のネイティブなC型で宣言されていること、(b)未処
   理のBoxedオペランドdropを伴う末尾値が「一時変数へ確定させてから
   dropし、その後returnする」という形でレンダリングされていること
   (裸の`return`の直前にdropが来ることは決してない)、そして(c)
   -- **今やStage 4が実装されたので** -- 元の関数自身の再帰呼び出し
   が*worker*自身を直接ターゲットにしている(`idris2rc2_worker_Main_fib_0`
   であって`Main_fib`ではない)こと、どちらの呼び出しの周りにも
   `idris2rc2_mkInt64`/`idris2rc2_to_i64`の対が一切残っていないこと
   を確認できる。`tests/BenchLoop.idr`自身の`Main.sumTo`がループ組み
   合わせのスモークテストである -- そのworker自身のループ出口末尾値
   が同じネイティブ経路でレンダリングされていなければならない。
4. `tests/Test*.idr`/`tests/Bench*.idr`一式全体を、本物の`idris2 --cg
   refc`出力と突き合わせて確認する -- このプロジェクトの他の全ての
   段階と同じ。両段階とも純粋に構造/コード生成上の変更であるはずな
   ので、*全ての*テストが引き続きバイト単位で一致し、観測可能な挙動
   の差異はゼロでなければならない。2ファイル
   (`Test6NativeInts.idr`、`Test7CastMatrix.idr`)は`tests/`の*内側*
   から起動する必要がある(`tests/Test6NativeInts.idr`ではなく、裸の
   `Test6NativeInts.idr`)-- この2ファイルだけは他の全てのテスト
   ファイルのような`module Main`ではなく`module TestNNNN`を宣言して
   いるため、`tests/`プレフィックス付きのパスでコンパイルすると
   idris2自身のモジュール名がファイルパスと一致しなければならない
   というチェックに引っかかる; これは無改造の本家`idris2`に対しても
   全く同じ形で再現するので、`Compiler.RC2`とは無関係な、この2
   ファイル自身の既存の起動パス上の癖であり、事前に存在していたもの
   である。`Test7CastMatrix.idr`はさらに、現時点では本物の`idris2
   --cg refc`との突き合わせが一切できない: nixpkgs同梱のRefCサポート
   ライブラリ自体がコンパイルに失敗する(`idris2_negate_Double`が自身
   のヘッダの中で`idris2_nagate_Double`と誤記されている上、いくつかの
   宣言が欠落している)-- これはその参照用インストール自体の不具合
   であり、rc2とは無関係であると確認済み; `idris2-rc2`自身による同じ
   ファイルのビルドは問題なくコンパイル・実行できるので、これはこの
   1ファイルについての突き合わせ検証上の欠落であって、既知または
   疑われるrc2自身のバグではない。
5. **単なるstdout diffだけでは参照リークを捕まえられない** --
   `RAppNameRep`自身の引数処理には、1段階半(Stage 3aからStage 3bの
   大半まで)もの間、一度もdiffを落とすことなくバグが存在していた。
   計算される値そのものを一切破壊しないためである。`RAppNameRep`
   自身のエミッション、あるいは`Compiler.RC2.DualABI`自身の
   worker/wrapper合成への変更は、`tests/Test11DualABILeak.idr`に対する
   `valgrind --leak-check=full`でも必ず確認すること(自身の昇格された
   パラメータの値を意図的にsmall-intキャッシュ範囲外へ押し出してあり、
   `Main.fib`/`Main.sumTo`自身の再帰でそうだったように、欠落したdrop
   が沈黙のno-opとして隠れることができない) -- `definitely lost: 0
   bytes in 0 blocks`を期待する(100件の不滅なsmall-intキャッシュ分
   だけが`still reachable`として表示されるべきである)。
6. **Stage 4が実際に呼び出しサイトを書き換えるようになったら、パフォ
   ーマンスの向上を直接検証すること** -- `time ./build/exec/<BenchFibの
   出力>`を数回、本物の`idris2 --cg refc`でビルドした同じファイルに
   ついても同様に実行して比較する。`fib 30`(`tests/BenchFib.idr`)は、
   (このプロジェクト自身の歴史における、`BENCHMARKS.md`によればそれ
   までの全ての段階での)RefCと同等かやや劣る状態から、Stage 4が実際
   に書き換えを行うようになった後はおよそ**35%高速**になった --
   このプロジェクト自身の元々の目的そのものである。もし将来この
   パイプラインへの変更がこの数値をパリティ方向へ後退させるなら、
   それはかつて書き換え・昇格されていたある呼び出しサイトがもはや
   そうならなくなったという本物の兆候であり、単なるノイズと片付ける
   前に`--directive dumprcexpr`と生成されたCの直接確認(上記ステップ
   2-3)で調査する価値がある。
