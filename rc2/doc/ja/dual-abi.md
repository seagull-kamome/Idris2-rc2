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
RC (normalize+annotate) -> Reuse -> MutualLoop -> Loop -> DualABI -> Emit
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
dumpdualabi`デバッグダンプ(`--directive dumprcexp`をミラーし、
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
  メンバー別wrapper(`Test10MutualLoop.idr`の
  `Main.isEvenM`/`isOddM`/`stepA`/`stepB`) -> 正しく何も適格ではない
  (自分自身のパラメータを`ROp`/`RCmpCase`で使うことが一切ない --
  wrapper自身の本体はマージ関数への転送呼び出しでしかない)。

### Stage 3自身の計画を変えた発見

`MutualLoop`自身の*マージ*関数(`{rc2_mutualLoop:N}`、上記のメンバー
別wrapperとは対照的)は、グループのある1メンバーがネイティブとして
読む共有スロットについて、それとは*別の*、より小さいアリティの
メンバーが単に`RCNull`しか供給していない場合でも実際に適格性を示す
**ことがある** -- `Test10MutualLoop.idr`自身の`stepA`/`stepB`グループ
に対して直接確認済み(`{rc2_mutualLoop:0}: params=["1:Boxed",
"2:Boxed", "3:Int", "4:Int"]`)。これはまさに、`Compiler.RC2.Loop`
自身のネイティブshadow昇格の間に既に2回の実クラッシュを引き起こした
のと*同じ*形状である(`doc/loop-conversion.md`の「発見されたバグ」
#4参照) -- マージ関数自身の*外部*シグネチャにもネイティブworkerを
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
   のパターン)。
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

## ステータス

**実装・検証済み**(Stage 1、2、3a): IRの基盤、読み取り専用の適格性
解析、パラメータについてのworker/wrapper合成。`Main.fib`は、引数を
unbox化して合成されたworker(`rc2_dualABI_N`、`int64_t`パラメータ)を
呼び出す、変更されないBoxedシグネチャのwrapper(`Main_fib`)にコンパ
イルされ、本物の再帰処理を行う -- 正しい結果(`fib 30`について
`832040`)を計算することを確認済みであり、refc-suite全体(19/19)と
既存のスモークテスト/ベンチマークの一式を、`idris2 --cg refc`に対して
バイト単位で一致/クラッシュなしで再検証済み。**まだパフォーマンスの
変化はない** -- プログラム中の他のどこもworkerを直接呼んでおらず
(全ての呼び出しはまだ変更されないwrapperを経由する、1層薄くなった
だけ)、worker自身の戻り値もまだネイティブではない。この段階は意図的
に「他の何かリスクの高いものをその上に構築する前に、worker/wrapper
の形自体を単体で正しくする」ことにスコープを絞った --
`doc/loop-conversion.md`自身の先例が、この段階分けがなぜ報われるかを
示している。

**まだ実装されていない**:

- **Stage 3b -- ネイティブな戻り値。** `returnEligibility`が何かを
  見つけた時に、`RBoxed`を無条件に強制する代わりに、worker自身の
  `retRep`を昇格させる。`Compiler.RC2.Emit`自身の`Sink`/`SinkReturn`
  が`Rep`を意識するようになる必要がある(関数自身が決定した`retRep`
  を`emitInto`のディスパッチを通じて、末尾値が最終的にレンダリング
  される地点まで持ち回る)。また、`emitRC`+`finalizeSink`の既存の
  (常にBoxedな)経路に対応する、ネイティブな戻り値用の経路も必要
  (裸の`RV`末尾値には直接`rcVarToNativeC`(dropは不要、
  `tailValueReps`自身のシードが、それがネイティブだとマークした
  ものは構造的に本当にそうであることを保証しているため); `ROp`/
  `RPrimVal`形の場合は`emitNativeValue`と、`declareNative`自身のdoc
  コメントが説明しているのと*同じ*drop順序への配慮(`doc/
  native-type-inference.md`の「発見されたバグ」#4がまさに繰り返して
  はいけない間違いである: ネイティブな戻り値自身の未処理のBoxed
  オペランドのdropは、`return`文の*前に*、一時変数を介して必ず起きな
  ければならない -- `return`の後には、遅延されたdropが実行できる文の
  位置は存在しない))。`Emit.idr`自身の中でも最も呼び出し頻度が高く、
  最も依存されているコードの一部に触れるため、意図的にStage 3aから
  切り出し、それ自身で孤立した検証を行いたかった -- ブランチ自身の
  計画の議論を参照。
- **Stage 4 -- 呼び出しサイトの書き換え。** プログラム*全体*にわたる
  全ての関数自身の本体を(末尾位置だけでなく -- `RAppName`は`ROp`
  オペランドとしてなど、どこにでも現れ得る)歩き、今やworkerを持つ
  関数をターゲットとする直接・飽和呼び出しをすべて`RAppNameRep`に
  書き換える。引数/結果のレンダリングは*呼び出し元*が既に手元に
  持っている(あるいは欲しい)ものごとに選ぶ。ここで実際のパフォー
  マンスの向上が現れる -- 例えば`fib`自身の2つの再帰呼び出し(現在は
  まだ`Main_fib(idris2rc2_mkInt64(...))`のままで、毎回行きも帰りも
  box化している)が、直接の`rc2_dualABI_0(...)`呼び出しになり、
  最初から最後までネイティブになる。

### Stage 4に向けた未解決の設計課題

Stage 3a自身の「クロージャ遅延を常にスキップして安全、`RAppNameRep`
は決してトランポリン遅延されない」という論拠(上記「エミッション」
参照)は、全ての`RAppNameRep`呼び出しが固定された単一ホップの委譲
(wrapper -> 自分自身のworker、それ以外は何もない)であることに完全に
依存していた。Stage 4はプログラム全体にわたる**任意の**呼び出し
サイトに`RAppNameRep`呼び出しを導入することになり、その中には、
以前は`tryBuildClosureInto`がクロージャ経由で遅延させていた(トランポ
リンされるべき値として返し、*呼び出し元の*さらに呼び出し元が後で
解決できるようにする -- `Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`
が既に`goto`に変換する自己/相互再帰ではない形の、深さが未知の末尾
呼び出しチェーンについて、Cスタックの増大を抑えるため)本物の末尾
位置の委譲呼び出しも含まれる。Stage 4がもし*その種の*呼び出しサイト
を直接の、遅延されない`RAppNameRep`呼び出しへ書き換えてしまうと、
以前は保護されていた箇所で境界のないCスタック増大を再び持ち込みかね
ない。Stage 4が着地する前に: どの呼び出しサイトの形状がこの方法で
安全に書き換えられるかを正確に洗い出す必要がある(有力な候補: 最初は
*末尾位置ではない*呼び出しサイトだけを書き換える -- そこにはそもそも
クロージャ遅延が存在しなかった -- `emitRC`自身の既存の`RAppName`
`NotInTailPosition`ケースは*既に*呼び出しを即座に解決してその結果を
トランポリンしているので、それを直接の`RAppNameRep`呼び出しに置き換
えることは表現を変えるだけで、このスタック深さの性質は一切変えない;
遅延回避が本当の挙動の変化になる末尾位置の呼び出しサイトは、対象外の
ままにするか、それ自身の専用の安全性の論拠を先に必要とするかもしれ
ない)。

## ファイル

- `rc2/src/Compiler/RC2/DualABI.idr` -- `paramEligibility`/
  `returnEligibility`/`tailValueReps`(Stage 2)、`synthesizeWorker`/
  `applyDualABI`/`isMutualLoopMerged`/`FreshId`(Stage 3a)、
  `describeEligibility`/`dumpDualABI`(`--directive dumpdualabi`デバッグ
  ダンプ)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCFun`の新しい形、
  `RAppNameRep`。
- `rc2/src/Compiler/RC2/Loop.idr` -- `Compiler.RC2.DualABI`自身の再利用
  のため`export`化した`nativeArgType`/`stripOwnership`;
  `renameRCExp`内の防御的な`RAppNameRep`素通しケース。
- `rc2/src/Compiler/RC2/RC.idr` -- `MkRCFun`の新しい形に合わせて更新
  した`normalizeDef`/`annotateDef`; `annotate`内の防御的な
  `RAppNameRep`素通しケース。
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `MkRCFun`の新しい形に合わせ
  て更新(マージ関数と各メンバーのwrapperは共に、このパス自身の設計
  により無条件に常に`RBoxed`のまま)。
- `rc2/src/Compiler/RC2/Emit.idr` -- `createCFunctions`が関数自身の
  パラメータ宣言と`RepMap`シードについて`Rep`を意識するようになった;
  `emitRC`の新しい`RAppNameRep`ケース。
- `rc2/src/Compiler/RC2/Pretty.idr` -- `MkRCFun`の新しい`args`/
  `retRep`レンダリング; `RAppNameRep`自身の`callRep`レンダリング。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身のパイプライン配線
  (`applyLoop`の後に`applyDualABI`); `--directive dumpdualabi`の配線。

## 検証方法

1. `cd rc2 && source ../env.sh && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'`
2. `cd tests/refc-suite && nix-shell -p gcc gmp pkg-config --run './run.sh'` -- 19/19を期待。
3. `--directive dumpdualabi`(上記Stage 2自身の節参照)を任意の候補
   関数に対して使うのが、生成されたCを一切見る前に適格性を確認する
   最速の方法である -- 例えば`grep "Main.fib" out.dualabi`は
   `params=[Int] ret=Int`を示すはず。
4. `tests/BenchFib.idr`がStage 3aの標準的なスモークテストである:
   `fib 30`は依然`832040`を印字しなければならない; `grep -n
   "^IDRIS2RC2_Value \*rc2_dualABI" build/exec/*.c`はworkerが実際に
   合成されたことを確認し、その自身のC本体を直接読むことで、昇格
   されたパラメータが自身のネイティブなC型で宣言されていること、
   そして元の関数自身の再帰呼び出しが依然として(workerを直接では
   なく)*wrapper*(`Main_fib`)をターゲットにしていることを確認できる
   -- その特定の詳細が、Stage 4自身の呼び出しサイト書き換えがまだ
   誤って早期発火していないことの確認になる。
5. `tests/Test*.idr`/`tests/Bench*.idr`一式全体を、本物の`idris2 --cg
   refc`出力と突き合わせて確認する -- このプロジェクトの他の全ての
   段階と同じ。Stage 3aは純粋に構造/コード生成上の変更であるはずなの
   で、*全ての*テストが引き続きバイト単位で一致し、観測可能な挙動の
   差異はゼロでなければならない。
