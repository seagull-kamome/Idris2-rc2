# デュアル呼び出し規約(`Compiler.RC2.DualABI`)

(原文: `doc/dual-abi.md`。内容が乖離した場合は原文を正とする。)

rc2のデュアル(Boxed/ネイティブ)関数呼び出し規約の実装ノートである。
目的は、ネイティブ表現を通常の関数呼び出しの境界でも受け渡せるようにすることにある。
自己末尾呼び出しのループ内で`goto`を使う場合は、すでに`Compiler.RC2.Loop`が扱っている(`doc/loop-conversion.md`参照)。
本書が対象とするのは、それよりも広い範囲である。
将来のセッション(あるいは将来の自分)が、設計を一から導き直したり、すでに見つけて直したバグを再発見したりせずに、全体の文脈を取り戻せるように書いている。
ブランチ`dual-abi`に対応する。
後続のStageが入るたびに更新する生きた文書であり、現時点で何が実装済みで何が計画段階かは、末尾近くの「ステータス」を参照。

## 問題

ネイティブ型推論(`Compiler.RC2.Types`、`doc/native-type-inference.md`)が働くのは、1つの関数の本体の内部だけである。
関数の引数と戻り値は常にBoxedなので、ネイティブ表現にできる値でも、呼び出し境界を越える時点でbox化され、呼び出し先が読む時点で再びunbox化される。
`Compiler.RC2.Loop`のネイティブshadow昇格(`doc/loop-conversion.md`)は、ループが持ち回るパラメータ(1つのC関数の内部での、ある反復から次の反復への受け渡し)については、この往復をすでになくしている。
しかし、2つの異なる関数のあいだの通常の(末尾再帰でない)呼び出しは、毎回同じコストを払っている。

典型的な対象は`fib`である。

```idris
fib : Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
```

どちらの再帰呼び出しも`+`の内側にあるため、この関数は末尾再帰ではなく、`Compiler.RC2.Loop`は一切手を加えない。
関数本体全体(比較、減算、加算)は、既存のネイティブ型推論によってすでにネイティブRepになっている。
これは再帰呼び出しのオペランドの値がどこから来ていても変わらない。
それでも、呼び出しのたびに引数をbox化し、結果もbox化して返している。

## 設計: worker/wrapper分割(GHCの先例)

ネイティブなパラメータや戻り値を持てる関数ごとに、C関数を1つではなく**2つ**生成する。

- **wrapper**: 元のBoxedシグネチャをそのまま持つ関数。
  既存のあらゆる呼び出し元(クロージャ、FFI、間接ディスパッチ、書き換えの対象外だった呼び出し箇所)は、引き続きこちらを使う。
  本体は薄いシムで、適格な引数をそれぞれ変換してworkerを呼び出し、必要なら結果をBoxedに戻す。
- **worker**: 新しく合成する内部専用の関数。
  適格なパラメータと戻り値は、ネイティブのC型をそのまま使う。
  それ以外はBoxedのままである。
  本体には実際のロジックが入っており、元の関数の本体のコピーである。

これは古典的なworker/wrapper変換である(GHCも、厳密性にもとづくunboxingで同じ方法を使う)。
ネイティブ表現をすでに持っている(あるいはネイティブ表現だけを必要とする)直接・飽和の呼び出し箇所は、workerを直接呼べる。
そうすれば、wrapperの変換処理を丸ごと省ける。
**この書き換えを担うのはStage 4である**(実装済み。後述の「Stage 4」と「ステータス」を参照)。

### 全プログラム規模の不動点が不要な理由

当初の計画(`TODO.md`にある、この作業より前の「Dual calling convention」の項目)では、「エスケープ解析と、不動点によるシグネチャ推論パス」が必要だと想定していた。
つまり、手続き間の厳密性解析やunboxing解析で使う古典的な仕組みである。
実際には、**どちらの**適格性判定も、関数をまたぐ反復なしに、1関数ずつ局所的に答えられる。

- **パラメータの適格性**は、その関数自身の本体がパラメータをどう読むかだけで決まる。
  問うのは、一貫してネイティブコンテキストの`ROp`/`RCmpCase`のオペランドとして使われているかどうかである。
  これは`Compiler.RC2.Loop`の`nativeArgType`が問う内容と同じで、対象がループの持ち回りパラメータだけでなく、トップレベルの全パラメータに広がるだけである。
  他の関数の情報は一切関係しない。
- **末尾位置の戻り値の適格性**は、演算子自身の型タグ(`Types.opResultRep`)から決まる。
  この型タグは、オペランドがどこから来たかに依存しない。
  `fib(n-1) + fib(n-2)`は、`fib`がネイティブ値を返すと分かっているかどうかにかかわらず、すでにネイティブRepの`Add`である。
  既存のネイティブ型推論が、呼び出し境界の問題とは無関係にそう判断しているからである。

局所的に判定できない場面が1つだけある。
それ自身の算術を持たない、純粋な末尾呼び出しの委譲である(`g x = h x`。`g`の戻り値の適格性は`h`に依存する)。
これはv1の意図的な制限であり、不動点を追いかけず、非適格のままにしている。
既存のネイティブRepタグは、オペランドの出自にかかわらず`ROp`/`RCmpCase`を通じて伝播する。
このことから、このケースは実際にはあまり多くないと見ている。
プロファイリングで多いと分かった場合は、見直す。

## IRへの追加

### `MkRCFun`の新しい形(Stage 1)

```idris
MkRCFun : (args : List (Int, Rep)) -> (retRep : Rep) -> RCExp -> RCDef
```

以前は`(args : List Int) -> RCExp -> RCDef`であり、全引数が暗黙にBoxedだった。
`RLoop`が自身のRepを持ち回る形を、単一ループではなく関数全体の粒度に広げたものである。
既存の構築箇所(`RC.idr`の`normalizeDef`、`MutualLoop.idr`のマージ関数と各メンバーのwrapper)は、すべて一様に`RBoxed`を渡す。
これは従来の暗黙の挙動と完全に一致する。
新しい形を実際に使い始める前に、純粋なリファクタリングとして先に導入し、`master`のコンパイラ出力とファイル単位で突き合わせて、バイト単位で同一であることを確認した。
この進め方は、`Compiler.RC2.Loop`のStage 1と同じである。

### `RAppNameRep`(Stage 3a)

```idris
RAppNameRep : FC -> Name -> (argReps : List Rep) -> (retRep : Rep) -> List RCLocal -> RCExp
```

`name`のworkerを直接・飽和で呼び出す式である。
`argReps`と`retRep`は、この呼び出し1つ1つが各引数と結果をどう表現するかを示す。
`RNative ty`なら生のネイティブ値を読み書きし、`RBoxed`なら通常の`RAppName`と同じ扱いになる。
クロージャを構築する位置(`RUnderApp`、あるいは`tryBuildClosureInto`が本来クロージャに遅延させる末尾位置)には置けない。
クロージャの引数スロットに入れられるのは`IDRIS2RC2_Value *`だけであり、ネイティブな引数を必要とする呼び出しは、その形では表現できないからである。
この式を生成するのは`Compiler.RC2.DualABI`だけで、このモジュールは`Compiler.RC2.Loop`の後に動く(後述の「パイプライン上の位置」を参照)。
それより前のパスは、この式を生成せず、入力として見ることも想定していない。
前のパスで`RCExp`を網羅的にマッチしている箇所(`RC.idr`の`annotate`、`Compiler.RC2.Loop`の`renameRCExp`)には、防御的にこの式をそのまま通す節を追加した。
既存の`RLoop`/`RLoopContinue`の節と同じ考え方である。

## パイプライン上の位置

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.InlineCExp      (whole-program inlining, before lambda lifting)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (constructor-reuse-in-place)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue,
                                    plus native-shadow promotion)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite -- this module)
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

`DualABI`を`Loop`の後に置くのは、自己末尾再帰関数のパラメータの適格性を、`Compiler.RC2.Loop`がすでに決めた`RLoop.loopParams`からそのまま読み取るためである。
自分で導き直す必要がなくなる(後述の`paramEligibility`を参照)。
`DualABI`は`MutualLoop`の後にも動く。
そのため、`MutualLoop`が合成したマージ関数は、worker合成の対象から明示的に外さなければならない(後述の「Stage 3の計画を変えた発見」を参照)。

## Stage 2: 適格性解析(`paramEligibility`/`returnEligibility`)

読み取り専用の解析であり、何も合成せず、何も書き換えずに適格性だけを判定する。
Stage 3の危険な書き換えを載せる前に、新設した`--directive dumpdualabi`のデバッグダンプ(`--directive dumprcexpr`と同様に、`<outfile>.dualabi`へ書き出す)で検証した。
設計の誤りを、直すコストの小さいこの段階で見つけるためである。
所有権の除去やコード生成のバグと絡み合った後では、原因の切り分けが難しくなる。

### `paramEligibility : List Int -> RCExp -> List (Int, Maybe PrimType)`

本体が`Compiler.RC2.Loop`によってすでに`RLoop`で包まれている場合は、そのループの`loopParams`から位置対応で答えをそのまま読み取る。
`RLoop`の`initial`は、各ループパラメータの初期値を、構造上つねに同じ位置のトップレベル引数から読む(`Compiler.RC2.Loop.applyLoop`の`initial = map RCLoc argIds`)。
したがって、`loopParams`の各項目は`argIds`と位置が揃っており、ここでは追加の確認が要らない。
そうでない場合は、`Compiler.RC2.Loop`の`nativeArgType`を使う(再利用のために`export`した)。
ループの持ち回りパラメータだけでなく、トップレベルの全パラメータに対して問う。

### `returnEligibility` / `tailValueReps`

`tailValueReps`は、本体のすべての末尾位置の値(`RLoopContinue`を除く)を走査する。
その際、すでにネイティブと分かっているローカルを`SortedMap Int Rep`に保持して持ち回る。
初期値は`paramEligibility`の結果なので、適格なパラメータをそのまま末尾で返す場合もネイティブとして扱われる。
走査が`RLet`や`RLoop`の束縛を通過するたびに、この写像を拡張する。
裸の`RV`/`ROp`/`RPrimVal`は、そのRepを直接読み取る。
呼び出し、クロージャ、コンストラクタ、extprim、消去、crashは、文脈にかかわらず決してネイティブにならない。
前述の設計メモのとおり、純粋な委譲の連鎖が非適格になるのは、まさにこのためである。
`returnEligibility`が`Just ty`になるのは、すべての末尾値が同じ`ty`で一致する場合に限る。

### 検証での発見

既存のテストとベンチマークのスイートで、次を確認した。

- `Main.fib`(`tests/BenchFib.idr`)は`params=[Int] ret=Int`になった。
  この取り組み全体が狙っていた、非末尾再帰の代表例である。
- `Main.sumTo`(`tests/BenchLoop.idr`)は`params=[Int, Int] ret=Int`になった。
  `Compiler.RC2.Loop`が下した`RLoop`の判断から、正しく読み取れている。
- `Main.countDown`/`Main.collatzLike`(`tests/Test110Loop/SelfTailLoop.idr`)は、1つの関数のなかでネイティブなパラメータとBoxedなパラメータが混在する形で、正しく判定された。
- `Main.swapLoop`と、`Compiler.RC2.MutualLoop`が生成した各メンバーのwrapper(`Test110Loop/SelfTailLoop.idr`の`Main.isEvenM`/`isOddM`/`stepA`/`stepB`)は、適格なものがないと正しく判定された。
  どれも、自身のパラメータを`ROp`/`RCmpCase`で使っていない。
  wrapperの本体は、マージ関数への転送呼び出しだけだからである。

### Stage 3の計画を変えた発見

`MutualLoop`の**マージ関数**(`{rc2_mutualLoop:N}`。上記の各メンバーのwrapperとは別物である)は、共有スロットに対して、実際に適格と判定されることがある。
グループのあるメンバーがそのスロットをネイティブで読む一方で、別の、アリティの小さいメンバーは、そこに`RCNull`しか渡さない場合である。
`Test110Loop/SelfTailLoop.idr`の`stepA`/`stepB`のグループで直接確認した(`{rc2_mutualLoop:0}: params=["1:Boxed", "2:Boxed", "3:Int", "4:Int"]`)。
この形は、`Compiler.RC2.Loop`のネイティブshadow昇格の際に、実際に2回のクラッシュを起こしたものと同じである(`doc/loop-conversion.md`の「Bugs found」#4を参照)。
マージ関数の外部シグネチャにまでネイティブworkerを持たせると、境界が変わるだけで、同じ危険が再び現れる。
各メンバーのwrapperは、そもそも適格なものがないので、除外を意識しなくても対象から外れる。
一方、マージ関数は**明示的に**除外する必要があった。
`Compiler.RC2.DualABI`の`isMutualLoopMerged`が、`MutualLoop.idr`の`freshName`が付ける`MN "rc2_mutualLoop" _`という名前パターンに一致するものを検出し、worker合成を完全にスキップする。

## Stage 3a: worker合成(パラメータのみ)とwrapperの書き換え

`synthesizeWorker`は、全プログラム対象の`applyDualABI`から、適格かつ`MutualLoop`のマージ関数でない関数ごとに呼ばれる。
処理は次の順に進む。

1. 新しいworker名を作る。
   `freshName`/`freshId`/`FreshId`を使い、`Ref`でカウンタを持ち回る。
   これは`MutualLoop.idr`がすでに使っている方式と同じである。
   名前は`idris2rc2_worker_`に、元の関数のマングル済みC名(`Compiler.RC2.Emit.Util`の`cName`。再利用のために`export`した。wrapperがそのまま使うC名と、まったく同じマングリングである)と、重複を避けるカウンタを続けたものになる。
   たとえば`Main.fib`のworkerは`idris2rc2_worker_Main_fib_0`である。
   ランタイムが所有するCシンボルには`idris2rc2_`接頭辞を付けるというプロジェクトの規約に沿っており、生成物であることが分かる。
   どの関数のworkerかも名前から分かる。
   以前の、グローバルカウンタだけの不透明な`rc2_dualABI_N`とは違う。
2. `workerArgs`を作る。
   適格な位置のパラメータは`RNative ty`に昇格し、それ以外は`RBoxed`のままにする。
   **元のパラメータのidをそのまま使うので、名前の付け替えは一切要らない。**
   これは`Compiler.RC2.Loop`のshadow idの方式より、はっきり単純である。
   あちらで新しいidが必要だったのは、同じ関数のなかで、すでにあるCパラメータに新しい表現を後付けする必要があったからである。
   すでに`IDRIS2RC2_Value *`として宣言した名前で`int64_t var_p`をもう一度宣言すると、Cの再宣言エラーになる。
   workerは**まったく新しい**C関数なので、そのidで衝突する既存の宣言がない。
   元のidを、新しいネイティブ型でworkerのシグネチャにそのまま宣言し直せる。
3. `workerBody`を作る。
   元の本体をそのまま使い、昇格したパラメータの所有権管理のうち、不要になったものを`Compiler.RC2.Loop`の`stripOwnership`(`export`した)で取り除く。
   手順2では名前を付け替えていないので、付け替えたshadowの集合ではなく、元のパラメータidに対して直接呼ぶ。
   `stripOwnership`が安全である理由は、「除去対象のidを値として読む箇所は、この時点でどれも一貫してネイティブになっている」というものである。
   この理由は、`Compiler.RC2.Loop`で使う場合とまったく同じ形でここにも成り立つ。
   `stripOwnership`のドキュメントコメントは、2つの呼び出し元の両方を説明するよう更新した。
4. `workerDef`を作る。
   `MkRCFun workerArgs retRep workerBody`であり、**`retRep`は元の関数のものをそのまま渡す**(現時点では常に`RBoxed`)。
   `returnEligibility`が何を見つけたかにかかわらず、ここでは昇格しない。
   これはStage 3aが意図的に限った範囲である。理由は後述の「ステータス」を参照。
5. `wrapperBody`を作る。
   workerへの`RAppNameRep`呼び出しを1つだけ置く。
   引数は元のパラメータ1つにつき1つで、その位置でworkerが決めた`Rep`に従って表現する。
6. `wrapperDef`を作る。
   `MkRCFun args retRep wrapperBody`であり、シグネチャとidは元の**まま**である。
   このため、プログラム中の既存の呼び出し元は、一切変更せずに動き続ける。

### 出力(`Compiler.RC2.Emit`)

変更は2つあり、Stage 3aが動くCを生成するには、この2つが揃っていなければならない(実際に痛い目を見て確認した。後述の「Bugs found」を参照)。

- **`createCFunctions`**(関数のトップレベルのC宣言を作る)が、パラメータリストについて`Rep`を考慮するようになった。
  各パラメータのC型は、常に`IDRIS2RC2_Value *`とするのではなく、その`Rep`から決める(`RNative`/`RInlineNative`なら`nativeCType ty`、`RBoxed`なら`IDRIS2RC2_Value *`)。
  `RepMap`は、どのローカルがどの`Rep`を持つかを随時記録する表で、あらゆる*使用*箇所が参照する。
  これを空から始めるのをやめ、最初に関数自身のパラメータで初期化するようにした。
  こうしないと、C宣言のほうはすでに正しくネイティブになっていても、本体内でのネイティブパラメータの*読み取り*が、Boxedとして出力されてしまう(何も登録されていないときの`repOfLocal`の既定値がBoxedだからである)。
  `MaxExtractFunArgs`を超える数のパラメータを持ち、そのうち1つ以上がネイティブであるworkerは、現時点では明示的な`InternalError`になる。
  これは、後述する`RAppNameRep`の出力側の制限と揃えたものである(「ステータス」を参照)。
- **`emitRC`に追加した`RAppNameRep`の節**は、各引数をその`Rep`に従って出力する(`tryEmitLoopContinue`が確立している、位置ごとの処理と同じ形である)。
  workerを直接呼び、結果を`retRep`に従って処理する。
  実装済みなのは`RBoxed`だけで、それ以外は`InternalError`になる。
  末尾位置でなければトランポリン経由にし(通常の`RAppName`とまったく同じ挙動である)、末尾位置であればそのまま返す。

  **通常の`RAppName`と違い、末尾位置でもクロージャによる遅延をしなくて安全な理由。**
  `tryBuildClosureInto`は、`RAppNameRep`をそもそも横取りしない。
  クロージャの引数スロットにはネイティブ値を入れられないため、この呼び出しは、末尾位置かどうかにかかわらず、つねに即時の本物のC呼び出しとして出力される。
  Stage 3aでこのノードを生成するのは、wrapperが自分のworkerを呼ぶ場合だけである。
  この場合は、安全であることを証明できる。
  呼び出しはつねにちょうど1段であり(wrapperは他の何も呼ばない)、有界でない再帰の連鎖の一部にもならない。
  だから、通常のクロージャ遅延やトランポリンを省いても、もともと起こり得なかった箇所でCスタックが際限なく伸びることはない。
  **この安全性の論拠は、Stage 3aの狭い使い方(トポロジーが固定の、1段だけの委譲)に固有のものである。**
  Stage 4が行う、はるかに広い範囲の呼び出し箇所の書き換えに、そのまま当てはまるわけではない。
  Stage 4がこの問題をどう解決したかは、後述の「Stage 4」の「範囲: 非末尾位置の呼び出しのみ、恒久的に」を参照。
  任意の呼び出し箇所に対して同じ論拠を証明しようとはせず、末尾位置の呼び出し箇所には一切手を付けないことにした。

## Stage 3b: ネイティブな戻り値

`returnEligibility`が適格と判定した場合、workerの`retRep`を`RNative ty`に昇格する。
`synthesizeWorker`は、適格な戻り値の型`retEligible : Maybe PrimType`を、wrapperの`wrapperRetRep`とは別に受け取るようになった。
`wrapperRetRep`は元の関数の`retRep`のままである(`Compiler.RC2.DualABI`の更新済みドキュメントコメントを参照)。
`applyDualABI`が「この関数にworkerを作るか」を判定する条件は、「適格なパラメータが1つ以上ある」から、「適格なパラメータが1つ以上ある、**または**適格な戻り値がある」へ広がった。
適格なパラメータは1つもないが、ネイティブにできる戻り値を持つ関数(たとえば、昇格すべき数値パラメータのない閉じた計算)も、範囲は狭いが実在するので、これで扱える。
戻り値の側は、`isMutualLoopMerged`による一括除外ですでにカバーされている。
どちらの側が適格になったかにかかわらず、マージ関数のworker合成は完全にスキップされるからである。

Stage 3bをStage 3aとは別のStageにしたのは、`Sink`/`SinkReturn`(`Compiler.RC2.Emit.Util`)の仕組みに手を入れるからである。
この仕組みは`Compiler.RC2.Emit`の出力エンジン全体に行き渡っている。
Stage 3aをパラメータのみに絞ったとき、「このモジュールの、最も通る頻度の高いコードの一部への、かなりリスクの高い変更」だとして切り離したのが、まさにこの部分である。

### 設計: `Sink`のフィールド1つと、分岐点1つ

実際の変更は、リスク評価から想像するよりも小さくて済んだ。
`Emit.idr`の制御フローが、もともとよく集約されていたからである。
分岐を持つ構文(`RCmpCase`/`RConCase`/`RConstCase`/`RLoop`)は、どれも同じ`Sink`を、再帰的な`emitInto`呼び出しを通じて各分岐へ渡していく。
その行き着く先は、本物の葉の式を扱う、ただ1つのフォールバック節である。
したがって、変更は次の3点で足りた。

- **`Sink`の`SinkReturn`コンストラクタに`Rep`フィールドを追加した**(`SinkReturn Rep`。以前はペイロードのない`SinkReturn`だった)。
  これは、囲んでいる関数の`retRep`である。
  `createCFunctions`が一度だけ渡す(`emitInto EmptyFC (SinkReturn retRep) InTailPosition body`。以前はペイロードなしの`SinkReturn`だった)。
- **`resolveSink`/`finalizeSink`/`chainsWithElse`/`buildClosureIntoSink`**には、*ロジック*の変更は一切必要なく、新しいフィールドを受け取れるようにパターンを広げただけである(`SinkReturn _`)。
  これらの挙動は、returnがどの`Rep`を持つかには依存せず、変数への代入でなく`return`であるという点にだけ依存するからである。
  (後に`SinkVar`にも同じ理由で`Rep`を持たせた。こちらは`resolveSink`/`finalizeSink`が実際に読む。後述の「分岐する値へのネイティブ昇格の拡張」を参照。)
- **`emitInto`の唯一のフォールバック節**では、`Rep`を実際に調べる。
  ここは、本物の葉の値(`RV`/`ROp`/`RPrimVal`など)が最終的にすべてたどり着く、唯一の場所である。
  `SinkReturn (RNative ty)`/`SinkReturn (RInlineNative ty)`は、通常の「`emitRC`してから`finalizeSink`」の組ではなく、新設した`emitNativeReturn`へ振り分ける。
  それ以外の`Sink`には影響しない。

分岐を持つ構文は、どれも受け取った`Sink`をそのまま次へ渡しているだけである。
そのため、この分岐点1つで、ループの脱出値や、入れ子の深い`if`/`switch`の連鎖の内側から返される値も、ネイティブのまま出力できる。
`emitCmpCaseInto`/`emitConCaseInto`/`emitConstCaseInto`/`emitLoopInto`/`branchBody`自体には、まったく変更が要らない。
`Main.sumTo`(ループが持ち回るネイティブなパラメータと、ネイティブな戻り値の両方を持つ)が、この経路を通る。
ループの脱出箇所(`if (tmp_3 == 0) { return var_4; }`)は、`Main.fib`の(ループでない)末尾位置と同じフォールバック節を通って出力される。

### `emitNativeReturn`: `return`の後に文を置く位置がない問題

`declareNative`(`RLet`のネイティブ束縛)は、これとよく似た問題をすでに解かなければならなかった。
`emitNativeValue`が持つ、Boxedオペランドのdropの保留分(そのドキュメントコメントを参照)は、値を読む文の*後*に実行する必要があり、前に置いてはいけない。
`RLet`なら、「後」は簡単である。同じブロックに、必ず次の文があるからである。
`return`には、そのような「後」がない。
制御が即座に関数を離れるので、裸の`return valStr;`の後に置いたdropは、決して実行されない。

`emitNativeReturn`は、`declareNative`と同じ2段階の形を取る(値を実体化し、*その後で*保留中のdropを実行する)。
ただし、一時変数を使うのは、順序を調整すべき保留中のdropが実際にあるときだけである。

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

一時変数には、既存の`tmp_N`の命名を再利用する(`getNewVarThatWillNotBeFreedAtEndOfBlock`。`makeClosure`が、宣言した文より後まで生き延びさせる必要があるときに、すでに使っている)。
本物の`RCLoc`のidが占める`var_N`の番号空間は使わない。
`declareNative`が`var_N`を使えるのは、木に対して番号付けされた本物のローカルを宣言しているからである。
こちらは、`RCExp`の木にidを持たない、出力時だけの合成の一時変数なので、`var_N`を再利用すると本物のローカルと衝突するおそれがある。

自明でない経路の代表例は、`Main.fib`のworkerである(再帰呼び出し2つの、それぞれBoxedの結果を、加算が読んだ*後で*dropする必要がある)。

```c
int64_t tmp_8 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));
idris2rc2_drop(var_3);
idris2rc2_drop(var_5);
return tmp_8;
```

基底ケース(`if n < 2 then n else ...`で、パラメータをそのまま返す場合)は自明な経路である。
保留中のdropがないので、一時変数も作らない。

```c
if (tmp_7 == UINT8_C(1)) {
    idris2rc2_drop(var_1);
    return var_0;
}
```

### `emitNativeValue`に追加した、裸の`RV`の節

`emitNativeValue`が扱う必要があったのは、Phase 1のANF正規化が`RLet`の末尾に渡し得るものだけだった。
`ROp`、`RPrimVal`、あるいは透過的なラッパーノード(`RLet`/`RDup`/`RDrop`/`RFree`/`RReleaseReuse`)である。
裸の`RV`は、そもそも来なかった。
「別のローカルをそのままコピーする」という`RLet`の束縛は、この経路では生じないからである。
ところが、`Compiler.RC2.DualABI`の`tailValueReps`(Stage 2)は、末尾位置の裸の`RV`(パラメータや、すでにネイティブな中間値をそのまま返す場合)を、つねにネイティブとして数えていた。
そしてStage 3bは、出力の時点でこのケースに実際に到達する最初のものである(前掲の`Main.fib`の、`if n < 2 then n else ...`の基底ケース)。
そこで、次の節を直接追加した。

```idris
emitNativeValue ty (RV fc v) = do
    valStr <- rcVarToNativeC ty v
    pure (valStr, [])
```

保留中のdropはない。
`ROp`のオペランドと違い、ここでの`v`は、構造上すでにネイティブと分かっている(`tailValueReps`の初期化が保証する)。
そのため、読み取り後に片付けるべきBoxedの読み取りがないからである。

### `RAppNameRep`のネイティブな`retRep`の節

workerの戻り値がネイティブに昇格したことで、そのworkerを呼ぶ*wrapper*側の呼び出し(`RAppNameRep`、Stage 3a)も、`RBoxed`以外の`retRep`を実際に持てるようになった。
以前は`InternalError`(「まだ実装されていない」)だった。
このノードに関する`emitRC`の契約は、この関数のほかのすべての節と同じく、「つねにBoxedの式の文字列を出力する」である。
`RBoxed`は従来どおり、末尾位置でなければトランポリン経由、末尾位置ならそのまま返す。
`RNative`/`RInlineNative`の場合、`call`はすでにworkerが返した生のネイティブ結果である。
そのため、末尾位置かどうかにかかわらず、`nativeMk ty call`で直接box化する。
ネイティブ値は「まだ解決されていないトランポリン」になり得ないので、どちらの場合でも遅延するものがないからである。
トランポリンはBoxed表現だけの概念であり、未解決の継続を符号化している可能性のある、タグ付きヒープポインタを指す。
具体例は、`Main.fib`のwrapperである。

```c
IDRIS2RC2_Value *Main_fib(IDRIS2RC2_Value * var_0)
{
    return idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(idris2rc2_to_i64(var_0)));
}
```

`emitAppNameRepInto`自身が行うのは、この向きだけである。
ネイティブなworkerの結果を、wrapperの(つねにBoxedな)末尾値のために、Boxedとして出力する。
Stage 3bが入った時点では、このノードを生成するのは`Compiler.RC2.DualABI`のwrapper本体だけであり、出力先もつねに`SinkReturn RBoxed`だった。
`RAppNameRep`の結果を、box化せずネイティブのまま出力したい呼び出し元は、結局Stage 4の課題になった。
ただし、`emitAppNameRepInto`を変える形ではない。
`emitNativeValue`に、`RAppNameRep`専用の節を別に設ける形である(後述のStage 4の「ネイティブへの昇格」を参照)。
Stage 4が導入する新しい形とは、呼び出しの結果を、一度もbox化せずに直接ネイティブへ昇格する`RLet`のことである。

### `createCFunctions`の戻り値型の宣言

最後の部品が、C関数宣言の戻り値型である(`IDRIS2RC2_Value *\{cName ...}`と、無条件に書いていた部分)。
これを`retRep`から決めるようにした。
`declareParam`が引数ごとにすでに行っている処理と同じ形である。

```idris
let retTypeStr : String = case retRep of
                                RBoxed => "IDRIS2RC2_Value *"
                                RNative ty => nativeCType ty ++ " "
                                RInlineNative ty => nativeCType ty ++ " "
let fn = "\{retTypeStr}\{cName !(getFullName n)}" ++ ...
```

`Main.fib`のworkerの前方宣言は`int64_t idris2rc2_worker_Main_fib_0(int64_t
var_0);`になる。
生成されたCを直接読んで確認した。これは、ほかのStageと同じ検証の進め方である。

## Stage 4: 呼び出し箇所の書き換え

実際の性能向上が得られるのは、このStageである。
3a/3bのように細かく分けず、1つのStageにまとめて着地させた。
「呼び出しを書き換える」半分は、検証済みの出力の仕組みを再利用するだけで済み(`emitAppNameRepInto`は、ネイティブの結果を必要に応じてすでにbox化できる)、新しいリスクはほとんどない。
一方、「それを囲む`RLet`を昇格する」半分があって初めて、書き換えが実際に効く。
前半だけでは、どの呼び出しも結果をbox化した直後にまたunbox化することになり、効果が小さすぎて別のStageにする価値がない。

### 範囲: 非末尾位置の呼び出しのみ、恒久的に

workerへ振り向けるのは、*通常の*RC2関数のworkerに対する、直接・飽和の**非末尾位置**の呼び出しだけである。
そのようなworkerへの末尾位置の呼び出しは、あとのStageで扱うのではなく、**意図的に恒久的な**対象外としている。
末尾位置の呼び出しは、現在`tryBuildClosureInto`によるクロージャ遅延で出力している。
値はbox化され、トランポリンで返り、*呼び出し元の呼び出し元*があとで解決する。
これによって、末尾呼び出しの連鎖のうち、深さが分からず、かつ`Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`が`goto`に変換できない形のもの(自己再帰でも相互再帰でもないもの)について、Cスタックの伸びを抑えている。
こうした呼び出しを、遅延しない直接の`RAppNameRep`呼び出しに書き換えると、スタックが際限なく伸びる問題が復活しかねない。
どの末尾位置の呼び出し箇所なら書き換えて安全かを見分けるには、手続き間の本格的な解析が必要になる。
それは、この取り組み全体が必要とせずに済ませてきた、全プログラム規模の不動点そのものにほかならない。
Stage 2の`returnEligibility`が、*純粋な*末尾呼び出しの委譲を追いかけず、非適格のままにしているのも、同じ理由による。

**FFI worker**(後述のStage 3c)への末尾位置の呼び出しだけは、この境界の例外である。
`%foreign`のcalleeが同じリスクを持たない理由は、Stage 5のあとにある「Stage 4b: 末尾位置のFFI呼び出し」を参照。

### workerテーブル

`workerTable`は、「どの関数がworkerを得たか、そのworkerの`(workerName, argReps, retRep)`は何か」を復元する。
`applyDualABI`を通したあとの定義リストを走査し、`synthesizeWorker`がwrapperに対してつねに作る形を探す。
その形とは、`MkRCFun _ _ (RAppNameRep _ workerName argReps retRep _ _)`であり、本体にはそれ以外が入らない。
`applyDualABI`から別のテーブルを引き回す必要はない。

### 書き換え: `applyCallSiteRewriteBody`

すべての定義の本体を走査する。
wrapper、worker、手を加えていない関数のどれであっても、まったく同じロジックで書き換える。
ここでは、定義がその3つのどれかを知る必要がない。
走査中は、局所的に分かっているRepの`SortedMap Int Rep`を持ち回る(`paramEligibility`/`tailValueReps`がすでに使っているものと同じ初期化と拡張である)。
あわせて、現在位置が*関数全体の*末尾位置かどうかを表す`Bool`も持ち回る。
これが`True`になるのは、トップレベルの入口だけである。
`RLet`の`body`、分岐を持つ構文の各分岐、各ラッパーノードの`cont`には、この値をそのまま渡していく。

微妙な点が1つある。
`RLet`の*値*は、見た目どおりの平らな葉(`ROp`/`RAppName`/`RCon`など)とは限らない。
Phase 1のANF正規化は、呼び出しの*引数*の式を、外側の`RLet`の値の**内側**に、さらに別の`RLet`として入れ子にする。

```
let v3 = (let v4 = n - 1 in fib v4) in
let v5 = (let v6 = n - 2 in fib v6) in
v3 + v5
```

このため、実際の呼び出しは、`RLet`が何段も連なった奥に入っていることがあり、`value`そのものであるとは限らない。
`RLet`の節は、この形に次のように対処する。
まず`value`に再帰する(非末尾モードで行う)。
その末尾に`RAppName`があれば、それも書き換える。
実際に何かを書き換える節は、この関数の包括的な節だけであり、`value`の末尾にはその節で到達する。
次に、書き換え後の`value1`の`ultimateTail`を調べる(同じ入れ子の`RLet`の形を剥がしていく)。
これで、*外側*の`RLet`(上の例なら`v4`/`v6`ではなく、`v3`と`v5`)が昇格の候補かどうかを決める。

`postDropFor`は、書き換えた引数のうちどれに明示的なdropが要るかを決めるのに、自前の生存解析を必要としない。
置き換え対象は、元の(まだ`RAppName`だった)呼び出しである。
それについて`Compiler.RC2.RC`の`annotate`が、すでに次のように決めている。
Boxedの引数を呼び出しに渡すと、参照が1つ消費される。
その引数のローカルがこの先でも必要なら、事前にdupする。
同じ引数をネイティブで読み、その場でdropしても、正味のコストはまったく同じである。
したがって、`annotate`が呼び出し箇所の周りに用意した管理は、どちらの場合でも釣り合いが取れている。

### ネイティブへの昇格: `nativePromotionFor`

`Compiler.RC2.Loop`の`nativeArgTypes`を直接再利用する(`nativeArgType`と並べて`export`した)。
問う内容は、関数のトップレベルのパラメータについてすでに問うていることと同じだが、対象が、`RLet`に束縛されたworker呼び出しの結果になる。
このletのスコープの残りが、その値を、workerの`retRep`の型で、一貫してネイティブコンテキストのオペランドとして読んでいるか、という問いである。
読んでいれば、`stripOwnership`を呼ぶ(これで3回目の再利用になる)。
ここでも名前の付け替えは不要である。新しい`RLet`の束縛であり、すでに宣言済みのC変数に後付けするわけではないからである。
`stripOwnership`は、`annotate`が、通常のBoxedローカルだと仮定して付けた、もう不要なBoxedの寿命管理を取り除く。
同じローカルを、ほかの場所でBoxedコンテキストで使う場合がある(たとえばコンストラクタのフィールドへの格納)。
その場合も、昇格の有無にかかわらず動き続ける。
`rcVarToBoxedC`が、ネイティブ値を必要に応じて再box化するからである。
再box化では、この呼び出しが以前生成していたものを共有せず、新しく確保する。
スカラ値には観測できる同一性がないので、Idrisのプログラムからは区別できない。

`fib`のworkerの、変更前と変更後を示す。

```c
// before Stage 4
IDRIS2RC2_Value * var_3 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_4)));
IDRIS2RC2_Value * var_5 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_6)));
int64_t tmp_9 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));

// after Stage 4
int64_t var_3 = idris2rc2_worker_Main_fib_0(var_4);
int64_t var_5 = idris2rc2_worker_Main_fib_0(var_6);
return (var_3 + var_5);
```

2つの再帰呼び出しの引数にも結果にも、box化もunbox化もdup/dropもない。
計算全体が、workerの入口から`return`まで、`int64_t`のまま進む。

### 昇格を呼び出し引数の連鎖へ拡張する: `callArgNativeReads`

`nativeArgTypes`/`bareTailNativeReads`が探すのは、`var`を`ROp`/`RCmpCase`のオペランドとして読む場合と、裸の末尾だけである。
3つ目の形は見落としていた。
`var`が、*別の*workerのネイティブな引数位置にそのまま渡される形である。
`fib(n-1) + fib(n-2)`のような形だけでなく、`ffiCall2 (ffiCall1 x) y`のような連鎖も含まれる。
Stage 5でFFI呼び出しが安価な葉ノードになり、連鎖させやすくなったので、この形は増えている。
`callArgNativeReads`が、この穴を埋める。
`nativeArgTypes`と同じ方法で`body`を走査し、裸の`RAppName`を見つけるたびに、`var`の出現を、そのcalleeの`workers`テーブルの項目と照合する。
この走査が動く時点で、`body`はつねにStage 4で書き換える前の部分木なので、呼び出しはまだ`RAppName`の形をしていて、`RAppNameRep`になっていない。
calleeの`argReps`がその位置を`RNative`/`RInlineNative`としていれば、その出現は数え、`RBoxed`の位置なら数えない。
`nativePromotionFor`は、これを、ほかの2つの情報源に並ぶ3つ目の情報源として和集合に加えるだけである。
対象の`workers`の項目が`True`(FFI、Stage 4b)か`False`(通常)かは、ここでは問題にならない。
Stage 4の*非末尾*の節は、どちらの種類も無条件に書き換える。
一方、通常のworkerへの、本物の末尾位置の呼び出し(クロージャで遅延したままにしてある)に出現する場合も、どちらでも正しく出力される。
クロージャのスロットが保持できるのはつねに`IDRIS2RC2_Value *`だけなので、`var`は、ほかのBoxedコンテキストの使い方と同じように、渡す際に再box化されるからである。
これは、`nativePromotionFor`自身がすでに依拠している、「必要に応じて再box化するので、正しさは保たれる」という論拠と同じである。

`rc2/tests/Test13NativeArgChain.idr`の`chainCallArg`/`addAbsCallArg`が、変更前と変更後の具体例になる(以前は別ファイルの`Test56NativeCallArgChain.idr`だったが、統合した)。
`addAbsCallArg`の本体はFFI宣言を呼ぶので、`Compiler.RC2.InlineCExp`の対象にならない。
その第1パラメータがネイティブになるのは、同じファイルの`chain`が扱う、入れ子の`RLet`の本体に関する修正のおかげだけである。
呼び出しそのものと、本物のネイティブな対象引数の両方が、Stage 4まで無傷で残るように、この2つを意図的に選んだ。

```c
// before this extension
IDRIS2RC2_Value * var_3 = (IDRIS2RC2_Value*)idris2rc2_mkInt64(abs(idris2rc2_to_i64(var_0)));
int64_t var_2 = idris2rc2_worker_Main_addAbsCallArg_1(var_3, var_1);

// after
int64_t var_3 = abs(idris2rc2_to_i64(var_0));
int64_t var_2 = idris2rc2_worker_Main_addAbsCallArg_1(var_3, var_1);
```

`var_3`は、2つの呼び出しのあいだで`IDRIS2RC2_Value *`を経由する往復をしなくなった。
`valgrind`でリークがないことを確認した(`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済み)。
`rc2/tests/verify.sh`全体でも確認し、90 passed、0 known、0 failedだった。

### 昇格を`case`のスクルーティニへ拡張する

実際のコードで最も効いた読み取り元が、これである。
`Compiler.RC2.Loop`の`nativeArgTypes`は、これまで`RConstCase`の*alt本体*だけを見ており、スクルーティニの位置は見ていなかった。
そのため、ネイティブな結果が`case`のスクルーティニとしてのみ読まれるworker呼び出しは、上記のどの情報源にも当てはまらず、`RBoxed`のままだった。

出力側に不足はなかった。
`Compiler.RC2.Emit`の`emitConstCaseInto`は、`Compiler.RC2.Loop`のネイティブshadow昇格が必要としたときから、スクルーティニをその`Rep`に従って(整数のswitchの経路でも、`Db`の等価比較の経路でも)ネイティブかBoxedで出力してきた。
欠けていたのは、適格性の判定だけだった。

スクルーティニの寄与は、`nativeArgTypes`/`nativeArgTypesFor`自体に入れた。
そのため、この2つの利用側3つが、同時にこの恩恵を受ける。
利用側とは、`Compiler.RC2.Loop`のパラメータshadow昇格、このStageの`nativePromotionFor`、`Compiler.RC2.LateInline`の`nativeEligible`である。
`applyLoop`のドキュメントコメントには、すでに「カウントダウンの`0`チェック」を対象にするべきだと書いてあった。
`LateInline`の`hasNonNativeUse`は、同じ変更のなかで、スクルーティニの出現を不適格の根拠として扱うのをやめる必要があった。
この関数と`nativeArgTypes`は、同じ`constAltsNativeType`を共有する。
2つの判定が一致しないと、一方がネイティブと呼ぶ値を、もう一方が拒否してしまうからである。

`constAltsNativeType`は、altが一致させる定数から、`Types.litRep`を使って型を決める。
`Types.litRep`は、`BI`と`Str`に対してはすでに`Nothing`を返す。
そのため、GMPの`Integer`や`String`のスクルーティニは、Boxedの読み取りのままになる。
この2つは、`emitConstCaseInto`がネイティブでの出力を持たない形である。
altの型が食い違う場合は、推測せずに完全に拒否する。
`nativePromotionFor`の単一性チェックも、ほかの情報源との食い違いを拒否する。

`RLoop`の`initial=`リストにも、同時に、同じ理由で同じ修正を入れた。
`Emit`の`declareLoopParam`は、各項目を`rcVarToNativeC`に通して出力する。このとき使うのは、*そのスロットの*`Rep`である。
したがって、すでに`RNative`のスロットを渡すことは、ネイティブの読み取りに当たる。
これは、`nativeArgTypes`がこれまで読み飛ばしていた「メタデータ」ではない。
1つ前の反復における`RLoopContinue`と同じ事情である。
`LateInline`の`hasNonNativeUse`も同様に、`initial`の出現を不適格の根拠とするのをやめた。
共有する`Loop.nativeSlotTy`に対して判定する。

idris2-lsp全体のビルド(24,343個の定義)で、`--directive dumprcexpr`の`callRep`行を使って測定した。

| `RLet`のRep <- workerの`retRep` | 変更前 | 変更後 |
|---|---|---|
| `Boxed <- Native Bits8` (rc2の`Bool`) | 187 | 73 |
| `Boxed <- Native Char` | 8 | 4 |
| `Native Bits8 <- Native Bits8` | 0 | 114 |
| `Native Char <- Native Char` | 4 | 8 |

昇格は118件で、そのうち114件が`Bool`だった。
実際のコードでは、この形のほとんどが`Bool`になる。
rc2はIdris2の`Bool`を`Bits8`として表現し、述語呼び出しに対する`if`は、すべてこの形になるからである。
該当する箇所ごとに、boxとunboxが1回ずつ、そして各アームの(何もしない)`idris2rc2_drop`がなくなる。

```c
// before
IDRIS2RC2_Value * var_555 = idris2rc2_mkBits8(idris2rc2_worker_..._Ord_Prec_2(var_558, ...));
IDRIS2RC2_Value * var_556 = NULL;
int64_t tmp_22 = idris2rc2_extractInt(var_555);
if (tmp_22 == UINT8_C(1)) { idris2rc2_drop(var_555); ... }
else                      { idris2rc2_drop(var_555); ... }

// after
uint8_t var_555 = idris2rc2_worker_..._Ord_Prec_2(var_558, ...);
IDRIS2RC2_Value * var_556 = NULL;
int64_t tmp_22 = var_555;
if (tmp_22 == UINT8_C(1)) { ... } else { ... }
```

`rc2/tests/Test13NativeArgChain.idr`の`classify`/`describe`が、`Int`と`Bool`の両方の形をカバーする。
`*Neg`という2つ目の呼び出し元も用意してある。これは、`Compiler.RC2.LateInline`の単一呼び出し元インライン化が、Stage 4が呼び出しを見る前にcalleeを展開して消してしまうのを防ぐためである。
`verify.sh`は、実行のたびに、どちらのworkerの結果もどの呼び出し箇所でもbox化されていないことを再確認する。
出力の差分では、これはまったく検出できないからである。

**この後もBoxedのまま残るもの、およびその理由。**
2つの別の事柄があり、混同しやすい(このセクションの以前の版は混同し、形も件数も誤っていた。ここで訂正した)。

1. **132件の直接worker呼び出しが、依然として`RBoxed`に束縛されている**(`Bits8`が73件、`Int`が55件、`Char`が4件)。
   昇格の取りこぼしではない。
   結果が流れ込む先が、本物のBoxedの位置だからである。
   たとえば、`call Prelude.Interfaces.guard`の引数、`con Prelude.Types.Right`のフィールド、`Core.Hash.hashWithSalt`である。
   こうした位置では、消費側が実際に必要とするのは`IDRIS2RC2_Value *`である。
   `nativePromotionFor`が、これらを昇格しないのは正しい。

2. **`let`の*値*が分岐で、そのすべてのアームがネイティブ値を生成する場合。**
   こちらのほうが、はるかに大きな穴だった。
   現在は塞がっている(後述の「昇格を分岐する値へ拡張する」を参照)。
   解決した問題は次のとおりである。
   Cには`case`の式形式がないので、box化は、分岐全体を包むラッパー1つでは済まなかった。
   **アームごとに1つ**必要で、そのうえ消費側が、あとでまたunbox化していた。

   ```c
   IDRIS2RC2_Value * var_556 = NULL;               // sink declared Boxed
   int64_t tmp_22 = var_555;
   if (tmp_22 == UINT8_C(1)) {
       var_556 = idris2rc2_mkBits8(idris2rc2_worker_..._firstCharIs_0_0(var_557));
   } else {
       var_556 = idris2rc2_mkBits8(UINT8_C(0));    // even a bare constant
   }
   IDRIS2RC2_Value * var_561 = NULL;
   int64_t tmp_23 = idris2rc2_extractInt(var_556); // and straight back out
   ```

   テストスイートが生成するCで測定すると、分岐のsink変数1,099個のうち、**254個(23%)は、すべてのアームが、新しくbox化したネイティブ値を代入している**。
   その254個のうち**236個(93%)は、消費側が再びunbox化している**。
   つまり、849回のbox化の呼び出しが、何の役にも立っていない。
   これは、このセクションの変更が同じコーパスから取り除く86箇所の、およそ10倍である。

   原因は構造にあった。
   `Compiler.RC2.Emit.Util`の`Sink`は、以前は`SinkVar Bool String | SinkReturn Rep`だった。
   `SinkReturn`は`Rep`を持つ(まさにStage 3bが追加したもので、ネイティブな末尾から生のスカラ値を`return`できるようにしている)。
   ところが`SinkVar`には何もなかった。
   そのため`resolveSink`は、つねに`IDRIS2RC2_Value * target = NULL;`と宣言し、各アームの`finalizeSink`は、代入の際にbox化しなければならなかった。

### 昇格を分岐する値へ拡張する: `branchValueNativeType`

Stage 3bの対象を、*戻り値*から*変数*へ一般化する。
次の3つの部分からなる。

- **`SinkVar`にも`Rep`を持たせた**(`SinkVar Bool String Rep`)。
  ネイティブの場合、`resolveSink`は`IDRIS2RC2_Value * target = NULL;`ではなく`uint8_t target = 0;`と宣言し、`finalizeSink`はそこへ生のスカラ値を代入する。
  この変更だけを先に入れ、すべての構築箇所が`RBoxed`を渡すようにしたところ、テストスイートが生成するCは、全体でバイト単位で同一のままだった。
  リファクタリングそのものが何も動かしていないことを、確認できたことになる。
- **`emitNativeSinkVar`**は、`emitNativeReturn`の、変数スロットに対する対になる関数である。
  returnの場合より単純である。
  代入の後には、つねに文を置く位置があるので、保留中のBoxedオペランドのdropはそこに置けばよく、一時変数は要らない。
  `emitInto`の振り分けは、sinkの`Rep`を調べるようになった。
  調べる位置は、`sink`を先へ渡していく構文(分岐、`RLoop`、`RMemoize`)の*後*であり、`RAppNameRep`/`RAppFFIInline`の*前*である。
  この2つには`emitNativeValue`にネイティブの節があるので、つねにBoxedで出力する側に回すと、workerのネイティブな結果を、ネイティブなスロットへそのままbox化して入れることになってしまうからである。
  `declareLet`の`RNative`の節も、同じ理由で`emitInto`を通す。
  分岐でないすべての値は、これで`emitNativeSinkVar`(`declareNative`そのもの)に届く。
- **`branchValueNativeType`**が適格性の問いに答える。
  `tailValueReps`/`allJustSame`を再利用し、すべてのアームの末尾が同じ`ty`のネイティブである場合に限り、`Just ty`を返す。
  このために、`tailValueReps`に`RAppNameRep`の節を加えた。
  この節に到達するのはStage 4の書き換えの*後*だけである。
  したがって、Stage 2の`returnEligibility`(元の定義に対して動くので、すべての呼び出しはまだ裸の`RAppName`である)と、`Compiler.RC2.LateInline`が以前行った再利用は、従来どおりのものを見る。
  `body`に対する`nativePromotionFor`の判定は変えていない。
  そのため、結果がBoxedの位置でしか読まれない分岐は、Boxedのままである。

テストスイートが生成するCで測定した結果は次のとおりである。

| | 変更前 | 変更後 |
|---|---|---|
| 全アームがboxedの分岐sink | 254 | **20** |
| そのbox化の呼び出し | 871 | **30** |
| `idris2rc2_mk*`(box化全体) | 2,176 | 1,329 |
| unbox化(`extractInt`/`to_i64`/...) | 1,269 | 1,030 |
| `idris2rc2_drop`の呼び出し | 8,175 | **7,606** |
| `IDRIS2RC2_Value *`の宣言 | 14,126 | 13,880 |

idris2-lsp全体のビルドでは、`RLet`のRepは、`Native`が1,333から**1,980**へ(+647)増え、`Boxed`が114,202から113,555へ減った。
残った20個のsinkは、本物の例外である。
ループの結果を持つsinkで、もう一方の「アーム」が`goto`であり、消費側がBoxedで読む場合が該当する。

`Prelude.Show`の`showPrec`が、変更前後の代表例である。
その`d >= App && firstCharIs ...`のガードは、端から端まで`uint8_t`になった。

```c
// before
IDRIS2RC2_Value * var_555 = idris2rc2_mkBits8(idris2rc2_worker_..._Ord_Prec_2(var_558, ...));
IDRIS2RC2_Value * var_556 = NULL;
int64_t tmp_22 = idris2rc2_extractInt(var_555);
if (tmp_22 == UINT8_C(1)) {
    idris2rc2_drop(var_555); idris2rc2_dup(var_557);
    var_556 = idris2rc2_mkBits8(idris2rc2_worker_..._firstCharIs_0_0(var_557));
} else {
    idris2rc2_drop(var_555);
    var_556 = idris2rc2_mkBits8(UINT8_C(0));
}
IDRIS2RC2_Value * var_561 = NULL;
int64_t tmp_23 = idris2rc2_extractInt(var_556);
if (tmp_23 == UINT8_C(0)) { idris2rc2_drop(var_556); ... }

// after
uint8_t var_555 = idris2rc2_worker_..._Ord_Prec_2(var_558, ...);
uint8_t var_556 = 0;
int64_t tmp_22 = var_555;
if (tmp_22 == UINT8_C(1)) {
    idris2rc2_dup(var_557);
    var_556 = idris2rc2_worker_..._firstCharIs_0_0(var_557);
} else {
    var_556 = UINT8_C(0);
}
IDRIS2RC2_Value * var_561 = NULL;
int64_t tmp_23 = var_556;
if (tmp_23 == UINT8_C(0)) { ... }
```

`rc2/tests/Test13NativeArgChain.idr`の`describeBoth`が回帰テストである(`isBig x && isBig y`は、まさにこの形に脱糖される)。
`verify.sh`は、出力された本体全体に、box化もBoxedの中間値もまったく含まれていないことを確認する。

## Stage 3c: FFI workerの合成

同じworker/wrapperの考え方を、`%foreign`の呼び出し境界にも広げる。
`MkRCForeign`の定義には、つねにBoxedなCスタブ(`Compiler.RC2.Emit`の`createCFunctions`)がある。
このスタブは、呼び出しのたびにすべての引数と戻り値をbox化・unbox化しており、これはupstreamのRefCと同じである。
関係するすべての位置がプリミティブな`CFType`で、そのネイティブなC表現が`%foreign`宣言の型から完全に分かっている場合でも、同じである。
Stage 2とは違い、解析すべき関数本体はない。

`MkRCForeign`は自前の`RCExp`の本体を持たない。
そのため、Stage 1〜4より狭い範囲になり、その違いは次の3点にそのまま現れる。

- **適格性の判定に解析は要らず、型の参照だけで済む。**
  `Compiler.RC2.Types.cfTypeNative : CFType -> Maybe PrimType`は、`nativeEligible`のFFI側の対になる関数である。
  `Int`/`Int8`/`Int16`/`Int32`/`Int64`/`Bits8`/`Bits16`/`Bits32`/`Bits64`/`Double`は、いずれも`nativeCType`と`cTypeOfCFType`の出力が完全に一致する。
  したがって、適格な位置は、workerの外側の境界で変換を必要としない。
  両側の呼び出し箇所がすでに合意している、同一のC値だからである。
  `CFChar`だけが例外である。
  `nativeCType CharType`は`uint32_t`(Idrisの`Char`の完全なUnicodeコードポイント)だが、`cTypeOfCFType CFChar`は1バイトの単なるC `char`である。
  これを除外せず、実際に食い違いが表面化する呼び出し境界で、明示的なキャストによって処理する。
  使うのは`nativeCharArgExpr`/`nativeCharRetExpr`で、これらは今も`Compiler.RC2.Emit`のヘルパーである。
  ただし、単独のworker本体の中で1回適用するのではなく、各`RAppFFIInline`の呼び出し箇所にインラインで適用する。
  この境界が現在実際にどこにあるかは、後述の「Stage 5」を参照。
  `rc2/tests/Test27FFIDualABI.idr`の`prim__bumpChar`のケース(コードポイント254 -> 255。どちらも単なる`char`の符号付き範囲を超える)は、`unsigned char`の段階を落として符号拡張してしまう回帰を検出するために、特に用意してある。
- **wrapperの書き換えはせず、元の`MkRCForeign`には手を加えない。**
  `Compiler.RC2.DualABI.ffiWorkerTable`が行うのは、テーブルの項目(`Name -> (workerName, argReps, retRep)`)を*追加する*ことだけである。
  `synthesizeWorker`が`MkRCFun`を薄いwrapperに書き換えるようには、`MkRCForeign`自体を書き換えない。
  **Stage 3aとは違い、このテーブルに対して、単独のworkerのC関数を出力することはない。**
  このテーブルを実際に使うものは、後述の「Stage 5」を参照。
  以前の設計は、worker関数を出力していた(その後削除した`Compiler.RC2.Emit.emitFFIWorker`と`Compiler.RC2.Emit.Util.FFIWorkers`のrefによる)。
  その2つはもう存在しない(後述の「Files」を参照)。
- **非末尾の場合、Stage 4には一切変更が要らなかった。**
  `%foreign`宣言された名前の呼び出し箇所は、呼び出し元のRCExpにすでに通常の`RAppName`ノードとして現れる(`Compiler.RC2.RC`の`MkAForeign -> MkRCForeign`の正規化は、そのまま通すだけで、呼び出し元の側にFFI固有の処理はない)。
  `applyCallSiteRewriteBody`の既存の書き換え規則は、対象にテーブルの項目がある非末尾の呼び出しを、その項目の由来がStage 3aでも3cでも、無条件にworkerへ振り向ける。
  どちらの場合も、合成したworkerの*名前*を指す通常の`RAppNameRep`ができる。
  `applyCallSiteRewrite`は、`ffiWorkerTable`の1つ目の戻り値を、`MkRCFun`のwrapperを走査して作る`workerTable`に和集合として加えるだけである(`mergeWith const`。2つのキー集合は常に互いに素であり、ある名前が`MkRCFun`と`MkRCForeign`の両方になることはない)。
  ただし、この`RAppNameRep`が、そのまま`Emit`まで残ることはない。直後の「Stage 5」を参照。
  (Stage 4には、あとで末尾位置の場合もカバーするために、小さな追加が1つ**必要になった**。Stage 5のあとにある「Stage 4b: 末尾位置のFFI呼び出し」を参照。)

## Stage 5: FFI-inline呼び出しの展開

Stage 3cのworker*名*が存在する理由は、Stage 4が`RAppNameRep`へ書き換える対象を与えることだけである。
`Emit`が動く時点では、その名前が単独のCの関数に対応することはないはずである。
以前の設計は、そのような関数を出力していた(つねにBoxedなwrapperに並べて、ネイティブなシグネチャを持つ2つ目のC関数`idris2rc2_ffiworker_*`)。
これをやめて、同じマーシャリングのロジックを、各呼び出し箇所に直接展開する設計に置き換えた。
展開には、新しいIRノード`RAppFFIInline`(`Compiler.RC2.RCExp`)と、専用のパス`inlineFFIWorkers`(`Compiler.RC2.DualABI`)を使う。
このパスが、一方を他方に置き換える。

`ffiWorkerTable`の1回の走査は、同じデータから作った*2つの*写像を返すようになった。
1つ目は、*元の*`%foreign`の名前をキーとし、従来のままのものである。Stage 4の入力になる。
2つ目は、*workerとして合成された名前*をキーとし、`inlineFFIWorkers`の入力になる。
Stage 4が作った`RAppNameRep`を、Stage 4がそのノードに付けたworker名で見分ける必要があるからである(元の関数の名前は、そのノードのどこにも現れなくなっている)。
この写像は、`MkRCForeign`の`ccs`/`fargs`/`ret`のフィールドを、そのまま持つ。
これらは、`RAppFFIInline`が呼び出しを直接出力するのに必要なものすべてである。

`inlineFFIWorkers`(ノードごとの走査を実際に行うのは`inlineFFIWorkersExp`)は、全プログラム対象の単独のパスとして、Stage 4の`applyCallSiteRewrite`の後に動く。
`applyCallSiteRewriteBody`に組み込まず別のパスにしたのは、`Compiler.RC2.InlineCExp`を`Compiler.RC2.RC`に組み込まず別のパスにしたのと同じ理由である。
Stage 4の`RAppName`/`RLet`の書き換えロジックは、それだけですでに込み入っており、FFI固有のマーシャリングの関心事まで加える余裕がない。
このパスは、純粋に構造的な、木全体の書き換えである。
Rep推論も所有権も末尾位置のロジックも自前で持たない(`Loop.idr`の`renameRCExp`や`ConstFold.idr`の木の走査関数とよく似ている)。
2つ目の写像に項目があるworkerを指すすべての`RAppNameRep`が、`RAppFFIInline`になる。
このとき`postDrop`と`args`は、完全にそのまま引き継ぐ。
これはつねに安全である。
`argReps = map repOf fargs`は、2つのノードの形のあいだで不変なので、Stage 4が所有権や昇格について決めたことは、木にどちらの形が残っても正しいままだからである。
`Compiler.RC2.RC2`のパイプラインは、これを`applyCallSiteRewrite`の直後に、`pure (inlineFFIWorkers ffiInlineMap rewritten)`として接続している。

`Emit.idr`は、`RAppFFIInline`を2通りに出力する。
`RAppNameRep`が、つねにBoxedで出力する場合とネイティブコンテキストの場合に分かれるのと対応している。

- **`emitAppFFIInlineInto`**(`emitInto`のノードごとの振り分けにあり、`RCmpCase`/`RAppNameRep`などと並ぶ)は、「余った、通常のBoxedの結果を返す呼び出し」の経路である。
  囲む`RLet`がこの呼び出しの結果をネイティブに昇格しなかったときに、いつでも使う。
  つねに*Boxed*の値の文字列を生成する。契約は`emitAppNameRepInto`と同じである。
- **`emitNativeValue`の`RAppFFIInline`の節**は、その、ネイティブコンテキストの対になる経路である。
  `Compiler.RC2.DualABI`のStage 4の`RLet`昇格が、すでにこの呼び出しの結果をunboxedのままにすると決めたときに、代わりにこちらを使う。
  Stage 4が存在する理由である、`fib`型の「box化してすぐunbox化する往復を省く」ケースが、FFI呼び出しでも起こるようになった。

両者は、ヘルパー`ffiRawCall`を共有する(これ自体は、引数ごとの`ffiArgMarshal`の上に作ってある)。
`ffiRawCall`は、次の処理を行う。

- `%foreign`宣言のC側の対象を解決する(`resolveForeignTarget`。`emitGenericForeignWrapper`のwrapper側の解決と共有している)。
  同じ宣言のwrapperがすでに一度ヘッダやライブラリの登録を済ませているので、ここでは別の登録は要らない。
- 各引数を、その`CFType`に従ってマーシャリングする。
  `cfTypeNative`で適格な位置は、`rcVarToNativeC`で直接読む。
  `CFChar`は、後述する`nativeCharArgExpr`/`nativeCharRetExpr`の、縮める/広げるキャストを通す。
  それ以外は、`rcVarToBoxedC`と`extractValue`を通す。
- 呼び出しそのものを出力する(`fctName(...)`。`CFIORes CFUnit`の対象なら裸の文、それ以外なら式になる)。

`emitAppFFIInlineInto`は、そのうえで生の結果を`packCFType`でbox化する(明示的な`(IDRIS2RC2_Value*)`キャストを付ける。後述の「Bugs found」を参照)。
`emitNativeValue`の節は、結果をネイティブのままにする。`CFChar`の結果は`nativeCharRetExpr`で広げる。

`CFChar`の縮める/広げるキャスト自体は、当初のStage 3cの設計から変わっていない。
変わったのは、単独のworker本体の中で1回行うのではなく、各インライン呼び出し箇所で行う点だけである。
`nativeCType CharType`は`uint32_t`(Idrisの`Char`の完全なUnicodeコードポイント)で、`cTypeOfCFType CFChar`は1バイトの単なるC `char`である。
`nativeCharArgExpr`は、`fctName`に渡す際に`(char)`へ縮める。
`nativeCharRetExpr`は、戻ってくる際に`(uint32_t)(unsigned char)`で広げる。
直接`(uint32_t)`にキャストしないのは、最上位ビットが立った`char`を、符号拡張ではなくゼロ拡張するためである。
つねにBoxedなwrapperは、同じ縮小と拡大を、`idris2rc2_to_char`/`idris2rc2_mkChar`ですでに払っている。
ここでの違いは、box化とunbox化の往復ではなく、レジスタ幅のキャストで済ませることだけである。
`rc2/tests/Test27FFIDualABI.idr`の`prim__bumpChar50`のケース(コードポイント254 -> 255。以前の`Test50FFIInlineNoWorker.idr`から取り込んだ)は、同じファイルの`prim__bumpChar`のケースがつねに検出してきた回帰を、worker本体ではなくインライン経路で検出する。

取り込んだ`prim__add50`/`prim__mixed50`/`prim__noop50`/`prim__bumpChar50`のグループが、Stage 5専用の回帰・スモークテストである。
同じファイルにあった、当初のStage 3cのシグネチャのカバレッジ(引数と戻り値がすべてネイティブ、`Int`と`String`が混在するシグネチャ、`CFChar`の縮小・拡大の往復、`Int`引数とBoxedな`CFUnit`のIO戻り値)を、新しい設計の下で踏襲している。
`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済みである。
本物の`idris2 --cg refc`とバイト単位で一致することと、リークがないこと(`valgrind --leak-check=full`で`definitely lost: 0 bytes`)を確認した。
さらに、手作業で`Test27FFIDualABI`と`Test118FFI/WideDualABIWorker.idr`が生成した`.c`に対して`grep -c idris2rc2_ffiworker_`を実行し、どちらも`0`だった。
単独のFFI workerのC関数は、どこにももう出力されない。
以前の`emitFFIWorker`による設計は、デッドコードとして残っているのではなく、本当になくなっている。

`rc2/tests/Test27FFIDualABI.idr`の200000回のループで再測定した(`--directive nodualabi`とのA/B、`time`、各5回で、各側の最初のコールド実行1回を除外)。
dual-ABIありでは約0.058秒(FFIがインライン化されており、worker関数は一切ない)、なしでは約0.073秒で、およそ**20%高速**である。
これは、このセクションが以前、単独workerの設計について報告していた約18%と整合しており、実行ごとのばらつきの範囲では、それよりやや良い。
呼び出し箇所への展開に書き換えても、置き換えたworker/wrapper方式に比べて何も失っていないことが確認できた。
`fib`の35%より小さいのは、このループの本体が、FFI呼び出しだけでなく、FFIとは無関係の実際の処理(大きな整数リテラルのキャスト)も行うからである。

## Stage 4b: 末尾位置のFFI呼び出し

Stage 4の「範囲: 非末尾位置の呼び出しのみ、恒久的に」は、末尾位置の呼び出しを書き換えの対象から外している。
通常のRC2関数のworkerは、それ自身がさらに別の末尾呼び出しで終わることがあり、深さの分からない連鎖になり得る。
その連鎖を抑えるために、`tryBuildClosureInto`のクロージャ遅延の仕組みがあるからである。
`%foreign`宣言のworkerは、そうならない。
外部のCコードへの、不透明な呼び出しが1回あるだけで、1回で戻り、このモジュールの末尾呼び出しの仕組みにはまったく関与しない。
したがって、この範囲の境界が防いでいるリスクは、FFI workerでは生じない。

`ffiWorkerTable`の1つ目の戻り値(`Name -> (workerName, argReps, retRep, Bool)`)は、この区別を末尾の明示的なタグとして持つ。
自身が生成するすべての項目に`True`を付ける。
通常のworker向けの`workerTable`(`MkRCFun`から作るテーブル)は、自身の項目に`False`を付ける。
`applyCallSiteRewrite`は、従来どおり2つのテーブルを`mergeWith const`でマージする。
ただし、対象はタグ付きの型になる。
マージしたテーブルは、そのまま`applyCallSiteRewriteBody`に渡す。
この関数の非末尾の`RAppName`の節は、タグを無視する(どちらの種類のworkerへ振り向けても、つねに安全である)。
新しい末尾位置の節は、タグを読み、タグが`True`のときに限って、飽和した呼び出しを書き換える。

```idris
applyCallSiteRewriteBody workers reps True value@(RAppName fc _ n args) =
    case lookup n workers of
         Just (workerName, argReps, workerRetRep, True) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
         _ => value
```

パイプラインには、これ以上の変更は要らなかった。
Stage 5(`inlineFFIWorkers`)は、木のすべての`RAppNameRep`を走査し、2つ目のテーブルに項目がある名前を探す。
末尾位置かどうかは問わない。
そのため、この新しい節が生成する`RAppNameRep`も、非末尾のものと同じように`RAppFFIInline`になる。
`Emit.idr`の`emitAppFFIInlineInto`も、`TailPositionStatus`/`Sink`をすでに正しく受け渡している。
その`SinkReturn`の分岐は、保留中のBoxed引数のdropを、素の`return`の前に出力する。
これは、通常のネイティブな末尾値に`emitNativeReturn`が使う順序と同じである。
最初から汎用的に書いてあったので、この呼び出し箇所が初めて本物の末尾位置で到達可能になっても、`Emit`側の変更は要らなかった。

変わるのは、*呼び出し箇所*の出力だけである。
*呼び出す側*の関数自身が、dual-ABIの適格になるわけではない。
`tailAbs n = prim__abs n`の`tailAbs`自身は、依然として、つねにBoxedな通常のwrapperを得る。
Stage 2の`tailValueReps`は、この呼び出しを含め、末尾位置の呼び出しをつねに非ネイティブとして扱う。
これは、前掲のStage 2「検証での発見」に書いた、*純粋な末尾呼び出しの委譲*の制限であり、意図的にそのままにしてある。
変わるのは、`tailAbs`の本体が、`prim__abs`の呼び出しを、あとでトランポリンに解決させるBoxedのクロージャとして遅延しなくなる点だけである。
`abs`を直接呼び、返す直前にその結果をbox化する。経路が1段短くなる。

`rc2/tests/refc-suite/callingConvention`(Stage 4のゴールデンスナップショットテスト。その`README.md`の項目を参照)が、まさにこの形の生成Cを固定している。

## 見つけて直したバグ

1. **Stage 3aの導入時に、`createCFunctions`がまだ`Rep`を考慮していなかった。**
   workerの最初のエンドツーエンドのビルド(`BenchFib.idr`の`fib`)で、*生成したCがコンパイルできなかった*。
   wrapperは引数を正しくunbox化し、生の`int64_t`でworkerを呼んでいた。
   ところが、workerのC側のシグネチャは、`IDRIS2RC2_Value * var_0`のままだった。
   Stage 1は、この側を`Rep`対応にするのを意図的に先送りしていた(当時のモジュールのノートに、「ここで`RBoxed`でない値を最初に生成するものと、同時に作る」とある)。
   `createCFunctions`がC宣言のために各パラメータの`Rep`を参照するようにし、`RepMap`を関数自身のパラメータで先に初期化することで直した(前掲の「出力」を参照)。
   これは最初からの計画だった。
   実際に動かして検証できるものが現れるまで作らないのが、このプロジェクトの確立した規律であり、それに従っただけである。
   `doc/loop-conversion.md`の「Bugs found」は、この規律が緩んだときに何が起こるかの、大部分が記録になっている。
2. **`declareLoopParam`のNULLガードが、`initVal`がすでにネイティブでも無条件に適用されていた。**
   これは、プロジェクトの検証一式(refc-suiteだけではない。この広い検証を標準の方法論に含めているのは、まさにこのためである)で見つかった。
   `Test111Basics/Basics.idr`の`Main.loop`と、`Test110Loop/SelfTailLoop.idr`の`countDown`/`collatzLike`で、`-Wall`でクリーンなビルドが、合成したworkerの内部で`comparison between pointer and integer`により失敗した。
   根本原因は次のとおりである。
   自己末尾再帰(すでに`RLoop`で包まれており、`Compiler.RC2.Loop`の`declareLoopParam`が、ループ入口のunbox化を`MutualLoop`の`RCNull`パディングから守るために、無条件にガードを付ける。`doc/loop-conversion.md`の「Bugs found」#4を参照)であり、かつdual-ABIの適格でもある関数があるとする。
   その関数のworkerでは、`Compiler.RC2.Loop`の`declareLoopParam`が動く時点で、トップレベルのパラメータがすでに`RNative`(`RBoxed`ではない)になっている(`Compiler.RC2.Emit`の`createCFunctions`が、ループ自身の宣言よりも前に、そのように登録するからである)。
   `declareLoopParam`のNULLガードは、`initVal`(「囲んでいる関数のトップレベルの、つねにBoxedな引数のどれか」)が、すでにネイティブであることはあり得ないという前提で、全面的に書かれていた。
   `Compiler.RC2.DualABI`のworker合成は、この前提が成り立たなくなる、まさにその場合に当たる。
   `rcVarToNativeC`自体は、これをすでに正しく扱っていた(ネイティブのローカルは、変換を出力せずそのまま読み返す)。
   しかし、それを包む*ガード*(`(initValName == NULL) ? 0 : (...)`)は、`initValName`がポインタでなく素の`int64_t`だと、型検査を通らない。
   修正は、先に`repOfLocal initVal`を調べることである。
   ガード(とそのすぐ後のBoxed値のdrop)を適用するのは、`initVal`が本当にまだ`RBoxed`の場合だけにする。
   すでにネイティブな`initVal`には、ガードなしの素の宣言を出力する。
   再検証の結果、以前失敗した4つのファイルがすべて再びビルドでき、本物の`idris2 --cg refc`と比較しても、バイト単位で一致した。
   refc-suite全体(19/19)にも影響はなかった。

Stage 3b(ネイティブな戻り値)では、新しいバグは見つからなかった。
実装の前に設計レビューを行い、`emitInto`の振り分け点が1つであるという構造と、`emitNativeReturn`に必要な「実体化してからdropして、returnする」という正確な順序を、コードを書く前に詰めた。
そうしなければ、おそらくここに3つ目の項目が加わっていたはずである。
最初のビルドは、そのまま通った。
後述の検証一式(`Main.sumTo`の、ループとネイティブな戻り値の組み合わせを含む。上のバグ#2に最も近い例である)も、修正なしで通った。

3. **`RAppNameRep`が、ネイティブで読んだBoxed由来の引数を、すべてリークしていた。**
   Stage 4(呼び出し箇所の書き換え)の設計中に見つかった。
   Boxedの値をネイティブで読む呼び出し箇所を*さらに増やす*前に、すでにStage 3aのwrapperが、昇格した全パラメータについてまさにそれを行っていたので、信用するだけでなく、実際に調べ直した。
   `rcVarToNativeC`は、`RAppNameRep`が`RNative`/`RInlineNative`のRepの位置の引数を出力するときに使う、unbox化のアクセサである。
   これ自身はdupもdropもしない(ドキュメントコメントを参照)。
   値を読むだけで、元のBoxedの参照は生きたまま残る。
   `ROp`/`RCmpCase`は、これを、`annotate`が決める`postDrop`フィールドによって、すでに正しく処理している。
   ところが`RAppNameRep`には、そのようなフィールドがなかった。
   しかも、`ROp`とは違い、`Compiler.RC2.DualABI`のworker/wrapperの合成は、そもそも`annotate`の所有権解析を通らない。
   `annotate`が定義全体をすでに処理し終えたずっとあとで、`RAppNameRep`のノードを直接作るからである。
   そのため、このdropが必要だと決める者が誰もいなかった。
   既存の検証一式では、`Main.fib`のwrapperでこれが表面化しなかった。
   `fib 30`の間にネイティブへ昇格する値が、すべて小整数キャッシュの範囲(`[0,100)`)に収まっていたからである。
   この範囲は、不死の、`refCount == IDRIS2RC2_REFCOUNT_MAX`の共有シングルトンに支えられており、その`idris2rc2_drop`は無条件に何もしない。
   そのため、dropが*欠けている*ことが、正しいdropと区別できなかった。
   これは、32ビット以下のポインタタグ付けで、このプロジェクトが以前にも一度痛い目を見た、「何もしない処理に隠される」形とまったく同じである。
   `valgrind --leak-check=full`で、人工的な最悪のケースを使って確認した(`tests/Test11DualABILeak.idr`。dual-ABIの適格な関数で、昇格するパラメータを、意図的にキャッシュの範囲の外へ追いやってある)。
   2,000,000回の呼び出しに対し、`31,999,984 bytes in 1,999,999 blocks definitely lost`であり、ほぼ*呼び出し1回につき*確保1回分がリークしていた。
   修正は、`RAppNameRep`に`postDrop : List RCLocal`のフィールドを持たせることで、`ROp`のものとまったく同じ形にした。
   `Compiler.RC2.DualABI`の`synthesizeWorker`は、これを追加の作業なしで埋められる。
   wrapperが昇格するパラメータのidそのものであり、別の目的で`eligible`としてすでに計算してあるからである。
   `Compiler.RC2.Emit`には、専用の`emitAppNameRepInto`を追加した。
   `RAppNameRep`は、`emitRC`の「つねにBoxedの文字列を出力し、保留中のdropのリストを持つ余地がない」という振り分けから、`emitInto`のノードごとの振り分けへ移した(`RCmpCase`/`RConCase`などと並ぶ)。
   この関数は、呼び出しの値が自身の文に埋め込まれた後で、`postDrop`を実行する。
   `SinkReturn`が対象の場合は、`emitNativeReturn`の「先に一時変数へ実体化する」手法を再利用する(`return`の後には、dropを置く文の位置がないからである)。
   `SinkVar`が対象の場合は、素直に「確定してからdropする」。こちらには、つねに文の位置がある。
   再検証では、同じ人工ケースで`valgrind`が`definitely lost: 0 bytes in 0 blocks`と報告した(`total heap usage: 14,000,124 allocs, 14,000,024 frees`。100ブロックの差は、不死の小整数キャッシュであり、リークではない)。
   refc-suite全体(19/19)と、`tests/Test*.idr`/`Bench*.idr`のマトリクス全体を、本物の`idris2 --cg refc`とバイト単位で再度diffしたが、影響はなかった。

4. **最初のStage 4の試みは、`fib`の再帰呼び出しを、実際には書き換えていなかった(エラーも出なかった)。**
   最初に動いたビルドは、コンパイルでき、正しく動いた(`fib 30`は`832040`のままだった)。
   このため、見逃しやすかった。
   生成されたCを直接読む(このプロジェクトの標準の規律である)ことで初めて、`idris2rc2_worker_Main_fib_0`の本体が、自分自身ではなく`Main_fib`(wrapper)を呼んでいることが分かった。
   根本原因は、`applyCallSiteRewriteBody`の最初の版が、`RLet`の`value`として*直接*置かれた呼び出しだけを認識していたことである。
   それ以外の経路で到達した裸の`RAppName`は、「関数全体の末尾位置のはずなので、そのままにする」と扱っていた。
   この前提は、手で試したすべての形では成り立っていたが、`fib(n - 1)`では成り立たなかった。
   Phase 1のANF正規化は、呼び出しの*引数*の式を、外側の`RLet`の値の**内側**に、さらに別の`RLet`として入れ子にする(`let v3 = (let v4 = n - 1 in fib v4) in ...`)。
   そのため、呼び出しそのものは、`RLet`の`value`にならず、走査の「末尾位置のはず」というフォールバックに飲み込まれていた。
   修正は、明示的な`inTail : Bool`を、走査全体に引き回すことである(`Compiler.RC2.Emit.Util`の`TailPositionStatus`に対応する)。
   これが`True`になるのは、定義のトップレベルの入口だけである。
   末尾かどうかを変えない構文には、そのまま渡していく。
   `RLet`の`value`に入るときは、*つねに*`False`にする。
   こうすると、裸の`RAppName`をそのままにするのは、`inTail = True`で到達した場合、つまり本当に関数全体の末尾位置の場合だけになる。
   それ以外の場所では、何らかの値の計算の連鎖の最終的な末尾であり、つねに書き換えて安全である。
   修正後の設計は、前掲の`applyCallSiteRewriteBody`のドキュメントコメントを参照。
5. **`nativeArgType`の、「裸の末尾は常にBoxed」という確立した前提は、Stage 4が動く時点では古くなっている。**
   上のバグ#4を直した後でも、`fib`のworkerは、2つの再帰呼び出しの結果をbox化していた(`idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(...))`)。
   その直後に`+`のために、またunbox化していた。
   昇格そのものが発火していなかった。
   `Compiler.RC2.Loop`の`nativeArgTypes`(昇格の判断に直接再利用している。前掲の「Stage 4」を参照)は、候補の変数を読む、裸の(さらなる`RLet`に束縛されていない)`ROp`/`RCmpCase`を、意図的に数えない。
   *そのパス自身の*呼び出し元(`Compiler.RC2.Loop.applyLoop`)にとっては、これは正しい。
   `applyLoop`は、どの関数の戻り値の適格性が決まるよりも、つねに厳密に前に動く。
   そのため、`applyLoop`が問う時点では、裸の末尾は本当に、まだ必ずBoxedである。
   ところが、`v3 + v5`は、`fib`のworkerの裸の末尾そのものである。
   Stage 4がパイプライン上で動く時点では、その末尾はすでにネイティブで出力されると分かっている(`Compiler.RC2.Emit`の`emitNativeReturn`、Stage 3b)。
   workerの`retRep`が、すでにネイティブだからである。
   `nativeArgType`を変更せずに再利用すると、このStage全体が存在する理由である、最も重要なケースを、気づかないうちに取りこぼしていた。
   `nativeArgTypes`/`nativeArgType`自体には手を触れずに直した(どちらも、ほかの場所ですでに十分に検証されている。そこで必要だった変更は、集合を返す`nativeArgTypes`を、すでに`export`済みの`nativeArgType`と並べて`export`することだけだった)。
   Stage 4専用の別関数`bareTailNativeReads`を追加し、この1つの追加の形を調べる。
   その結果を、最終的な「ちょうど1つの一貫した型」の判定の前に、`nativeArgTypes`の結果との和集合にする。
   生成されたCを直接読んで確認した。
   `fib`のworkerは、`int64_t var_3 = idris2rc2_worker_Main_fib_0(var_4); ...; return (var_3 + var_5);`と読めるようになった。
   2つの再帰呼び出しのどちらにも、box化も、unbox化も、dup/dropもない。
6. **トップレベルのパラメータが`MaxExtractFunArgs`(8)個を超える、dual-ABIの適格な関数が、コンパイラをクラッシュさせた。**
   見つけたのは、外部の実在するパッケージ([`idris2-missing-containers`](https://github.com/seagull-kamome/idris2-missing-containers)。再測定は`BENCHMARKS.md`を参照)に対してであり、このプロジェクト自身のテストスイートではない(これほど引数の多い関数が、スイートにはない)。
   `idris2 --cg refc -p missing-containers -p contrib Main.idr`が、`INTERNAL ERROR: [rc2] RAppNameRep: more than 8 args not yet supported`で即座に失敗した。
   根本原因は次のとおりである。
   `RAppNameRep`の出力(`emitAppNameRepInto`と`emitNativeValue`の該当する節。前掲の「Stage 3a」「Stage 4」を参照)には、引数が`MaxExtractFunArgs`個を超える場合の、`var_arglist[]`形式のBoxed配列から取り出すフォールバックがなかった。
   つねにBoxedな多引数の通常関数については、`createCFunctions`の経路がそのフォールバックをすでに持っている。
   このパッケージには、ラムダリフトされた内部ヘルパーのうち、9〜23個のパラメータ(外側のスコープから捕捉した自由変数)を持つものがあった。
   そのうち少なくとも2つは、ネイティブで適格なパラメータを実際に含んでいた。
   そのため、これだけ引数の多い関数にもworkerが合成され、wrapperからworkerへの呼び出しとして`RAppNameRep`も合成された。
   この問題はStage 3aから存在しており、Stage 4が持ち込んだものではない。
   コンパイラをStage 3a/3bまでさかのぼり、さらにこのブランチ全体の出発点となったdual-ABI以前のコミットまで、順にbisectして確認した。
   このパッケージに対して実際に試すまで、プロジェクト自身のスイートにはこの形がまったくなかったため、すべて同じクラッシュを再現した。
   修正は、取り出しのフォールバックを作る(実際の作業が要る。しかも、これほど引数の多い関数は、今後も少ないと見込まれる)のではなく、保守的に行った。
   `applyDualABI`の`synthesizeIfEligible`が、パラメータが`MaxExtractFunArgs`個を超える関数を、dual-ABIの適格から完全に、無条件に除外する。
   `paramEligibility`/`returnEligibility`が何を判定するかには関係しない。
   `isMutualLoopMerged`がすでに使っている、一括除外と同じ形である。
   `MaxExtractFunArgs`自体(`Compiler.RC2.Emit.Util`)は、この再利用のために`export`した。
   2つの上限が、うっかり食い違うことがないようにするためである。
   再検証では、refc-suite全体(19/19)と、`tests/Test*.idr`/`Bench*.idr`のマトリクス全体を、本物の`idris2 --cg refc`とバイト単位で再度diffした(これらにはこれほど引数の多い関数がないので、この除外の影響を実際に受けるものはない)。
   `valgrind`も、リークなしのままだった。
   **これとは別に**(dual-ABIのバグではなく、環境の問題でもない。ただし、最初はそう見えた)、`idris2-missing-containers`パッケージの`benchmarkHashMap`が、実行時にクラッシュするように見えた(`Unhandled input for Main.case block`)。
   `idris2-rc2`でも、変更していない上流の`idris2 --cg refc`でも同じ症状が出た。
   このブランチの元になったすべてのコミットまで、bisectでさかのぼっても、毎回同じ失敗が再現した。
   しかし本当の原因は、あとでワークスペースを一から再ビルドしたときに分かった。
   コンパイルしたベンチマークのバイナリを、誤った作業ディレクトリから実行していただけである。
   `Main.idr`の`benchmarkHashMap`は、パッケージルートからの相対パスで`test/words`と`test/input_large`を開く。
   `openFile`の失敗に対する`Left`の分岐は書かれていない。
   そのため、作業ディレクトリが誤っていると、バックエンドやコミットにかかわらず、毎回この「unhandled input」のクラッシュとして現れる。
   パッケージルートから実行すれば、3つのバックエンド(`idris2-rc2`、本物の`idris2 --cg refc`、Chez上の本物の`idris2`)すべてが正しく完了する(`BENCHMARKS.md`の再測定を参照)。
7. **続報: 上記の`MaxExtractFunArgs`個を超える引数の除外は、過度に保守的だった。一括除外のままにせず、きちんと直した。**
   そもそもなぜ除外が必要だったのかを見直した。
   項目6が先送りにした、`var_arglist[]`形式の取り出しのフォールバックは、`support/rc2/runtime.c`のクロージャディスパッチの関数ポインタ型(`IDRIS2RC2_FUN0`〜`FUN20`/`FUNSTAR`。すべて`IDRIS2RC2_Value*`のみ)に合わせるためだけに存在する。
   この規約が意味を持つのは、*`Closure`経由でディスパッチされる*可能性のある関数だけである。
   dual-ABIの**worker**は、そうならない。
   workerに到達できるのは、静的に名前の決まった、完全に飽和した直接の`RAppNameRep`呼び出し(自身のwrapperの本体から、またはStage 4の非末尾の呼び出し箇所の書き換えから)だけであり、`Closure`には格納されない。
   クロージャのディスパッチと互換性を保つ必要があるのは、**wrapper**(元の関数の名前で、つねにBoxed)のほうであり、項目6のクラッシュの原因は、そもそもwrapperではなかった。
   したがって、本当の修正は、項目6が先送りにした「実際の作業」であるフォールバックを作ることではない。
   workerにそのフォールバックを必要としない扱いを与えることである。
   `MkRCFun`に`isWorker`フィールドを追加した(`True`になるのは`synthesizeWorker`が作るworkerだけで、wrapperを含むほかのすべては`False`)。
   `Compiler.RC2.Emit`の`createCFunctions`は、`var_arglist[]`形式の宣言に切り替えるのを、worker以外が`MaxExtractFunArgs`個を超えるパラメータを持つ場合だけにした。
   workerは、パラメータの幅にかかわらず、位置ごとに個別の型を持つパラメータ(適格な位置はネイティブ)を保つ。
   `applyDualABI`の`synthesizeIfEligible`は、引数の多い関数をもう除外しない(残るのは`isMutualLoopMerged`だけである)。
   `rc2/tests/Test118FFI/WideDualABIWorker.idr`で検証した(パラメータ10個。ネイティブで適格な`Int`が9個と、`Boxed`の`String`が1個で、元の`idris2-missing-containers`の形に合わせてある)。
   生成されたCは、`idris2rc2_worker_Main_wideAdd_0`を、10個の個別のパラメータ(`int64_t`が9個、`IDRIS2RC2_Value *`が1個)で宣言する。
   呼び出しは直接で、`var_arglist[]`もbox化もトランポリンも関与しない。
   refc-suite全体、スモークテストのマトリクス、`valgrind`(`0 bytes definitely lost`)は、すべて引き続き通る。
   Stage 3c自身の、別立てのFFI workerの除外(`ffiWorkerTable`の`length fargs > MaxExtractFunArgs`)には手を付けなかった。理由は`TODO.md`の注記を参照。
8. **`MaxExtractFunArgs`自体を8から20に引き上げ、`support/rc2/runtime.c`もそれに合わせて拡張した。**
   項目7のworkerの除外免除と、Stage 3cの`ffiWorkerTable`の除外は、どちらも新しい閾値へ自動的に移る。
   同じ記号定数を使っているので、どちらの箇所にもコードの変更は要らない。
   ランタイム側は、実際に変更が必要だった。
   `idris2rc2_dispatchClosure`のswitchは、`case 0`〜`case 8`しか持たず、それより広いアリティは`default`/`IDRIS2RC2_FUNSTAR`に落ちていた。
   そのため、アリティ9〜20の本物の`Closure`は、型の付いた関数ポインタではなく、型のない`var_arglist[]`の経路を、気づかないうちに通ってしまう。
   これに該当するのは、ネイティブで適格なパラメータを持つ引数の多い関数の*wrapper*が、直接呼ばれずに部分適用される場合である(workerそのものは、項目7のとおり、この形でディスパッチされない)。
   `IDRIS2RC2_FUN9`〜`IDRIS2RC2_FUN20`のtypedef(既存の`FUN0`〜`FUN8`と同じ手書きの書式)と、`dispatchClosure`の`case 9`〜`case 20`を追加した。
   `runtime.c`には、`MaxExtractFunArgs`の所在として`Compiler/RC2/RC2.idr`を指す、古くなったコメントがあった。
   実際の所在である`Compiler/RC2/Emit/Util.idr`に直した。
   `rc2/tests/Test118FFI/WideDualABIWorker.idr`の`add20`(以前は別ファイルの`Test34WideClosureDispatch.idr`だったが、統合した)で検証した。
   20パラメータの関数に、本物の部分適用の連鎖(直接の飽和呼び出しではない)で到達する。
   これにより、本物の`Closure`と`dispatchClosure`を経由させ、新しい`case 9`〜`case 20`の経路を動かす。
   同じファイルの`wideAdd`/`prim__wide`は、worker側の幅の免除を動かす。
   `verify.sh`の`LEAK_SENSITIVE_TESTS`に登録し、`valgrind`で`0 bytes definitely lost`を確認した。
   refc-suite全体(19/19)とスモークテストのマトリクスは引き続き通り、`bench.sh`でも性能の後退はない。
9. **項目7の続報: Stage 3c自身の、別立てのFFI workerの除外は、項目7では手を付けなかったが、調べたうえで同様に取り除いた。**
   項目7では、`ffiWorkerTable`の`length fargs > MaxExtractFunArgs`の打ち切り(`DualABI.idr`の`ffiEntry`)を、無条件のまま残した。
   「calleeの側はクロージャディスパッチの規約を必要としない」という論拠が、おそらく同じく当てはまると注記したが、この構造的に別のコード経路(`MkRCFun`ではなく`MkRCForeign`)に対して、実際には確認していなかった。
   今回確認したところ、この論拠は、変更なしでそのまま当てはまる。
   FFI workerも、`Closure`には決して格納されない。
   クロージャの構築は、つねにwrapperの元の名前を使う。
   workerの名前に到達できるのは、静的に名前の決まった直接の`RAppNameRep`呼び出しだけである。
   そのため、幅の制限が守ろうとしていた`support/rc2/runtime.c`の`IDRIS2RC2_FUN0`〜`FUN20`/`FUNSTAR`の規約を、満たす必要がない。
   しかも、Stage 3aのworker合成の経路と違い、Stage 3cの`emitFFIWorker`(`Compiler.RC2.Emit`)には、そもそも迂回すべき、幅に依存する`var_arglist[]`のフォールバックがなかった。
   `declareParam`は、アリティにかかわらず、つねに位置ごとに個別の型を持つパラメータを出力する。
   したがって、項目6の元のバグは、ここでは構造上、起こり得なかった。
   `extractValue`/`packCFType`/`nativeCType`も、すべて純粋に位置ごとの、アリティに依存しない変換である。
   20パラメータを超えても形が変わるものは、その中にはない。
   そこで、`ffiEntry`の`if length fargs > MaxExtractFunArgs then pure [] else ...`という打ち切りを、完全に削除した。
   これで、すべての`%foreign`宣言が、アリティにかかわらず、ネイティブで適格な位置の検査(`if not (any anyNative argReps) && not (anyNative retRep) then pure [] else ...`)に必ず到達する。
   Stage 3cには、幅にもとづく除外が、どこにも残っていない。
   `rc2/tests/Test118FFI/WideDualABIWorker.idr`の`prim__wide`(以前は別ファイルの`Test48WideFFIDualABIWorker.idr`だったが、統合した)で検証した。
   これは15パラメータの`%foreign`宣言で、ネイティブで適格な`Int`が12個、`Boxed`の`String`が3個である。
   「大半はネイティブで、一部がBoxed」という形であり、しかも、以前の上限なら除外されていた幅である。
   `main`から完全に飽和した形で呼び、Stage 4の呼び出し箇所の書き換えが発火するようにした。
   生成されたCを手で調べると(この項目の時点、つまりStage 5が単独のFFI workerを廃止する前の話である)、`idris2rc2_ffiworker_Main_prim__wide_0`が、個別の型を持つ`int64_t`パラメータ12個と`IDRIS2RC2_Value *`パラメータ3個で宣言されている(`var_arglist[]`はどこにもない)。
   `main`の呼び出し箇所は、workerを直接呼んでおり、Stage 4の書き換えが発火したことが確認できた。
   Stage 5では、そのような関数は出力されず、呼び出しはインラインに展開される。
   `verify.sh --regen-expected`(スイート全体で85/85)と`refc-suite/run.sh`(19/19)は、どちらも引き続き通る。
   `valgrind --leak-check=full`は、このテストについて`0 bytes definitely lost`と報告した(`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済み)。
10. **リテラル定数のFFI引数が、Boxed引数のdropの追跡を壊し、Cのコンパイルが失敗した。**
    Stage 5の`emitAppFFIInlineInto`/`ffiRawCall`を作っている最中に見つかった。
    `ffiArgMarshal`の、Boxedの位置のdrop集合(のちに`ffiRawCall`の`boxedArgDrop`になったもの)の初期の版は、生の`RCLocal`を持っていた。
    これは、通常の`postDrop`の項目がすでに安全に使っている、素の`varName`で出力される。
    「dropされる引数は、すべて名前付きの変数である」というこの前提は、生のFFI呼び出しの引数については成り立たない。
    `RAppNameRep`の`postDrop`は、構造上つねに本物の`RCLoc`である(ドキュメントコメントを参照)。
    これと違い、`%foreign`呼び出しのBoxed型の引数は、それ自身がリテラルの`RCConst`であることがある(たとえば、囲む`let`なしに渡される`String`リテラル)。
    `varName`の`RCConst`の節は、`Emit.idr`のほかのすべての場所で、意図的に到達不能なプレースホルダーである。ほかには、そのような値を渡すものがないからである。
    そのため、宣言されていない、あるいは誤ったC識別子が出力され、静かな実行時バグではなく、コンパイルエラーになった。
    修正は、drop集合に生の`RCLocal`ではなく、出力済みのC式のテキストを持たせることである。
    `ffiArgMarshal`は、`(String, Maybe String)`を返すようになった(引数自身の出力と、本当にBoxedである場合のdrop用の出力)。
    後者は、定数のステージングや`InlineMap`をすでに正しく扱う`rcVarToBoxedC`で作る。
    その結果、`emitNativeValue`の「保留中のdrop」の契約が、プロジェクト全体で`List RCLocal`から`List String`に広がった。
    ほかの生成元(`RV`、`RAppNameRep`、`ROp`)は、すでに本物の`RCLocal`を手にしていた。
    したがって、これらの既存の呼び出し箇所に`map varName`が1つ増えるだけであり、挙動は変わらない。
    再検証では、`rc2/tests/Test27FFIDualABI.idr`の`prim__mixed50`(`String`型の引数)が、正しくコンパイルされ、動いた。
    `verify.sh`の全テストと`refc-suite/run.sh`(19/19)にも影響はなかった。
11. **`emitAppFFIInlineInto`のBoxed戻り値の経路で`(IDRIS2RC2_Value*)`キャストが欠けており、`-Wincompatible-pointer-types`でコンパイルが失敗した。**
    `emitGenericForeignWrapper`の既存のBoxed戻り値の処理は、`packCFType`の結果を明示的にキャストしている。
    `packCFType`の「mk」関数が、すべて文字どおり`IDRIS2RC2_Value *`を返すわけではないからである(たとえば、`CFStruct`/`CFPtr`の`idris2rc2_mkPointer`は`IDRIS2RC2_Pointer *`を返す)。
    `emitAppFFIInlineInto`(Stage 5のつねにBoxedの結果を返す出力関数)の最初の版は、構造上同一の`packCFType (peelIORes ret) rawExpr`呼び出しで、このキャストを省いていた。
    wrapper側のコードをコピーせず、新しく書いたからである。
    既存のテストスイートの、純粋にスカラ型の`%foreign`宣言では、問題は出なかった。
    それらの`packCFType`の結果は、たまたま`IDRIS2RC2_Value *`だからである。
    本物のコンパイルエラーとして表面化したのは、`CFStruct`やポインタを返す宣言だけである。
    この危険は、`emitGenericForeignWrapper`のコメントが、まさにこの形について、すでに指摘していたものだった。
    `rc2/tests/Test24CStructSupport.idr`の`prim__makePoint : Int -> Double -> PrimIO Point`が検出した。
    2つの引数はどちらもネイティブで適格なので、FFI workerが作られる。
    しかし戻り値の`Point`は`CFStruct`(Boxed)であり、`packCFType`が`IDRIS2RC2_Pointer *`を返す経路が動く。
    本物の非末尾位置(`main`の`do`ブロック内の`p <- primIO (prim__makePoint 3 4.5)`)で呼ばれているので、Stage 4/5がこの呼び出し箇所を実際に書き換え、`emitAppFFIInlineInto`のBoxedの結果の出力に到達する。
    修正は、wrapper側で確立している規約をそのまま踏襲し、同じ明示的な`(IDRIS2RC2_Value*)`キャストを加えることである。
    再検証では、`Test24CStructSupport.idr`が再び正しくコンパイルされ、動いた。
    `verify.sh`/`refc-suite`の全体にも影響はなかった。

## ステータス

**完全に実装され、検証済み**(Stage 1、2、3a、3b、3c、4、5)。

Stage 3c+5(FFI呼び出し箇所のインライン化)について。
`rc2/tests/Test27FFIDualABI.idr`の`prim__add`は、今もwrapper(`Main_prim__add`。Boxedシグネチャは変わらず、`extractValue`/`packCFType`にも手を加えていない)にコンパイルされる。
一方で、単独のworkerのC関数は、もう存在しない。
このテストの自己末尾再帰の`loop`は、`Compiler.RC2.Loop`によって、すでにネイティブな`int64_t`の`goto`ループになっている。
この`loop`は、本体の内側から`idris2rc2_test27_add`(`%foreign`宣言された、生のC関数そのもの)を直接呼ぶ。
呼び出しは、Stage 5が展開した`RAppFFIInline`ノードによるもので、box化もunbox化もなく、この呼び出しには間に挟まるworker関数もない。
本物の`idris2 --cg refc`とバイト単位で一致することと、リークがないこと(`valgrind --leak-check=full`で`definitely lost: 0 bytes`)を確認した。
refc-suite全体(19/19)とスモークテストのマトリクス全体も、引き続き通っている。
このテストの200000回のループ(`--directive nodualabi`とのA/B)では、dual-ABIを有効にすると約0.058秒、無効だと約0.073秒で、約20%高速になった(詳しい再測定は、前掲の「Stage 5」を参照)。

`Main.fib`は、wrapper(`Main_fib`。Boxedシグネチャは変わらず、ほかの場所にある既存の呼び出し元は、無修正で動き続ける)と、worker(`idris2rc2_worker_Main_fib_0`)にコンパイルされる。
workerは、実際の再帰処理を、すべてネイティブな`int64_t`で行う。
**2つの再帰呼び出しは、どちらもworkerを直接呼ぶようになった。**
この計算には、box化もunbox化もヒープ確保もdup/dropもなく、全体がworkerの入口から`return`まで`int64_t`のままである(生成されたCは、前掲のStage 4の変更前後のコード例を参照)。
正しく動くこと(`fib 30`で`832040`)と、リークがないこと(`valgrind --leak-check=full`で、`tests/BenchFib.idr`、`tests/BenchLoop.idr`、`tests/BenchChain.idr`、`tests/Test11DualABILeak.idr`のすべてについて`definitely lost: 0 bytes`)を確認した。
refc-suite全体(19/19)と、スモークテスト/ベンチマークのマトリクス全体も、本物の`idris2 --cg refc`に対してバイト単位で再検証した。
そして、この取り組みで初めて、性能向上を**実測**できた。
`fib 30`を直接計測すると(`time`、各3回)、`idris2-rc2`で約0.14秒、本物の`idris2 --cg refc`で約0.21秒であり、この取り組みの目的である、非末尾再帰の代表例で、およそ**35%高速**になった。

末尾位置の呼び出しは、恒久的に対象外のままである(前掲の「Stage 4」の「範囲」を参照)。
これは、今後のStageではなく、意図して慎重に引いた境界であり、Stage 2の`returnEligibility`における「純粋な委譲」の除外と整合している。

## ファイル

- `rc2/src/Compiler/RC2/DualABI.idr` -- 次を含む。
  - `paramEligibility`/`returnEligibility`/`tailValueReps`(Stage 2)。
  - `synthesizeWorker`/`applyDualABI`/`isMutualLoopMerged`/`FreshId`(Stage 3a+3b)。`synthesizeWorker`は、`workerArgs`と`workerRetRep`の両方を、`wrapperRetRep`とは独立に昇格する。
  - `describeEligibility`/`dumpDualABI`(`--directive dumpdualabi`のデバッグダンプ)。
  - `ffiWorkerTable`(Stage 3c)。解析すべき`RCExp`がないので、`paramEligibility`/`returnEligibility`は再利用しない。
    `freshName`は、明示的な`pfx`を受け取るようになり、Stage 3aの`"idris2rc2_worker_"`とStage 3cの`"idris2rc2_ffiworker_"`が、衝突を検査する1つの命名関数を共有する。
    1回の走査から*2つの*写像を返すようになった。Stage 4がつねに受け取っていた、元の名前をキーとする写像と、Stage 5が使う、workerの名前をキーとする写像である。
  - `workerTable`/`applyCallSiteRewriteBody`/`applyCallSiteRewrite`/`ultimateTail`/`bareTailNativeReads`/`branchValueNativeType`/`nativePromotionFor`/`postDropFor`/`localRepIn`(Stage 4)。
    `applyCallSiteRewrite`は、Stage 3cの、元の名前をキーとするテーブルを明示的な引数として受け取り、`MkRCFun`から作る`workerTable`に`mergeWith const`で併合する。それ以外は変わらない。Stage 4自身は、Stage 5の存在を知らない。
  - `inlineFFIWorkersExp`/`inlineFFIWorkers`(Stage 5)。`RAppNameRep`を`RAppFFIInline`へ書き換える、木全体の書き換えで、`applyCallSiteRewrite`の後に動き、Stage 3cの、workerの名前をキーとするテーブルを使う。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCFun`の新しい形、`RAppNameRep`(参照リークの修正のために追加した`postDrop`フィールドを、`ROp`のものと同じ形で持つようになった)、`RAppFFIInline`(Stage 5)。
  `RAppFFIInline`は、`%foreign`宣言の`ccs`/`fargs`/`ret`のフィールドをそのまま持つ。`RAppNameRep`の`argReps`/`retRep`とは違い、意図的に事前計算していない。
  置き換え元の`RAppNameRep`から、そのまま引き継ぐ`postDrop`フィールドも持つ。
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgType`/`nativeArgTypes`/`stripOwnership`を、`Compiler.RC2.DualABI`が再利用できるように`export`した。
  `renameRCExp`には、防御的な`RAppNameRep`の通過の節を追加した(`postDrop`の名前の付け替えも行う)。
- `rc2/src/Compiler/RC2/RC.idr` -- `normalizeDef`/`annotateDef`を、`MkRCFun`の新しい形に合わせて更新した。
  `annotate`には、防御的な`RAppNameRep`の通過の節を追加した。
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `MkRCFun`の新しい形に合わせて更新した(マージ関数と各メンバーのwrapperは、このパスの設計どおり、どちらも無条件につねに`RBoxed`)。
- `rc2/src/Compiler/RC2/Emit.idr` -- 次を含む。
  - `createCFunctions`が、関数の戻り値型の宣言と、各パラメータの宣言と`RepMap`の初期化の両方で、`Rep`を考慮するようになった。
  - `Sink`の`SinkReturn`コンストラクタが`Rep`を持つようになった(Stage 3b)。
  - 新設の`emitNativeReturn`。
  - `emitNativeValue`の、新しい裸の`RV`の節(Stage 3b)と、新しい`RAppNameRep`の節(Stage 4。昇格した`RLet`の、ネイティブを消費する出力のため)。
  - `emitInto`のフォールバック節が、ネイティブな`SinkReturn`に対して`emitNativeReturn`へ振り分けること。
  - `RAppNameRep`を、`emitRC`の振り分けから完全に外し、新設の専用`emitAppNameRepInto`(`emitInto`のノードごとの振り分けにあり、`RCmpCase`/`RConCase`などと並ぶ)に移した。この関数が`postDrop`を実行する。
  - `Compiler.RC2.DualABI`がworkerの命名で再利用できるように、`cName`を`export`した。
  - `nativeCharArgExpr`/`nativeCharRetExpr`(ネイティブな引数/戻り値が必要とする、`CFChar`だけの明示的なキャスト。現在は各`RAppFFIInline`の呼び出し箇所にインラインで適用する。前掲の「Stage 5」を参照)。
  - Stage 5自体としては、`resolveForeignTarget`(`emitGenericForeignWrapper`のwrapper側の解決と共有)、`ffiArgMarshal`/`ffiRawCall`(引数ごとのマーシャリングと呼び出しそのもの。次の2つの出力関数で共有する)、新設の`emitAppFFIInlineInto`(`emitInto`のノードごとの振り分けにある、つねにBoxedの結果を返す出力関数)、`emitNativeValue`の新しい`RAppFFIInline`の節(ネイティブコンテキストの出力関数。囲む`RLet`がこの呼び出しの結果をネイティブに昇格したときに使う)がある。
  - 削除済みの`emitFFIWorker`と、`Compiler.RC2.Emit.Util`の削除済みの`FFIWorkers`のref(以前の設計における、単独のネイティブシグネチャのFFI worker関数と、`createCFunctions`にそれを出力させるref)は、完全になくなった。現在、`%foreign`宣言に対して2つ目のC関数を出力するコードは、どこにもない。
- `rc2/src/Compiler/RC2/Types.idr` -- `cfTypeNative`(Stage 3cの、`CFType`側の適格性判定。`nativeEligible`のFFI版である)。
- `rc2/src/Compiler/RC2/Pretty.idr` -- `MkRCFun`の新しい`args`/`retRep`の表示。`RAppNameRep`の`callRep`の表示(`postDrop`を含むようになった)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`のパイプラインの接続である。
  まず`applyDualABI`、次に`ffiWorkerTable`(`(ffiWorkers, ffiInlineMap)`に展開する)、次に`applyCallSiteRewrite ffiWorkers`、最後に`pure (inlineFFIWorkers ffiInlineMap rewritten)`を実行する。
  Stage 5は、`Compiler.RC2.Emit`の前の、パイプライン最後のステップである。
  `--directive dumpdualabi`の接続は、影響を受けない(Stage 5より前の定義リストを、今も読む)。
  `FFIWorkers`のrefと、`generateCSourceFile`の先頭の引数は、もう存在しない。FFI-inlineテーブルは、IRの書き換えとしてのみ使われ、`Emit`の状態へは引き回さない。
- `rc2/tests/Test11DualABILeak.idr` -- 上記の参照リークのバグの回帰テストである。標準出力のdiffだけでなく、`valgrind --leak-check=full`で検証する(テストファイルのコメントを参照)。
- `rc2/tests/Test27FFIDualABI.idr`/`.c`/`.h` -- Stage 3c/5の、元の回帰・スモークテストである。
  以前は別ファイルだった`Test50FFIInlineNoWorker.idr`の、Stage 5専用のカバレッジも取り込んだ。これは、単独の`idris2rc2_ffiworker_*`のC関数がもう出力されないことを確認するために書かれた(`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済み)。
  上記の`Test11DualABILeak.idr`と同じ理由で、`valgrind --leak-check=full`で検証する。

## 検証の方法論

1. ビルドと回帰のベースライン: `CLAUDE.md`の「Build & test」のセクションを参照(`idris2 --build rc2.ipkg`の後に`tests/refc-suite/run.sh`を実行し、19/19を期待する)。
2. 候補の関数については、生成されたCを見る前に、`--directive dumpdualabi`(前掲のStage 2のセクションを参照)で適格性を確認するのが最も速い。
   たとえば、`grep "Main.fib" out.dualabi`は、`params=[Int] ret=Int`を示すはずである。
   このダンプは、*`applyDualABI`を通した後*の定義リストに対して動く(`RC2.idr`のパイプライン上の位置による)。
   関数のworkerが実際に合成された後では、*元の*名前は薄いwrapperを指す(設計どおり、パラメータも戻り値もBoxed)。
   そのため、ここでも`Boxed`/`Boxed`と正しく表示される。
   ネイティブに関する、興味深い結果は、workerが何で作られたかであり、それは生成されたCに直接現れる(次のステップ)。
3. `tests/BenchFib.idr`は、すべてのStageに共通の標準のスモークテストである。
   `fib 30`は、依然として`832040`を出力しなければならない。
   `grep -n "^int64_t idris2rc2_worker_\|^IDRIS2RC2_Value \*idris2rc2_worker_" build/exec/*.c`で、workerが実際に合成されたことを確認でき、その戻り値がネイティブになったかどうかも分かる。
   workerのC本体を直接読んで、次の3点を確認する。
   (a) 昇格したパラメータと戻り値が、ネイティブなC型で宣言されていること。
   (b) 保留中のBoxedオペランドのdropを伴う末尾値が、「一時変数へ実体化し、dropしてからreturnする」形で出力されること(裸の`return`の直前にdropが置かれることはない)。
   (c) **Stage 4が実装された現在は**、元の関数の再帰呼び出しが、*worker*(`Main_fib`ではなく`idris2rc2_worker_Main_fib_0`)を直接呼んでおり、どちらの呼び出しの周りにも、`idris2rc2_mkInt64`/`idris2rc2_to_i64`の組が残っていないこと。
   `tests/BenchLoop.idr`の`Main.sumTo`は、ループとの組み合わせのスモークテストである。そのworkerのループ脱出の末尾値は、同じネイティブの経路を通って出力されなければならない。
4. `tests/Test*.idr`/`tests/Bench*.idr`のスイート全体を、本物の`idris2 --cg refc`の出力とdiffする。このプロジェクトのほかのすべてのStageと同じである。
   どのStageも、純粋に構造的な、コード生成の変更であるはずなので、*すべての*テストが、観測できる挙動の違いなしに、バイト単位で一致しなければならない。
   `Test7CastMatrix.idr`だけは、現状、本物の`idris2 --cg refc`とのdiffによる確認ができない。
   nixpkgsに同梱されたRefCのサポートライブラリ自体が、コンパイルに失敗するからである(ヘッダ内で`idris2_negate_Double`が`idris2_nagate_Double`とタイプミスされており、さらに宣言の欠けがいくつかある)。
   これは、参照用のインストール自体の欠陥であり、rc2とは無関係であると確認している。
   同じファイルを`idris2-rc2`でビルドしたものは、問題なくコンパイルでき、動く。
   したがって、これはこの1ファイルのクロスチェックにおけるカバレッジの穴であり、rc2のバグが分かっている、あるいは疑われているわけではない。
5. **標準出力のdiffだけでは、参照リークは検出できない。**
   `RAppNameRep`の引数の扱いには、Stage 3aからStage 3bの大部分まで、1つ半のStageにわたってリークがあったが、diffは一度も失敗しなかった。
   計算結果の値を壊さないからである。
   `RAppNameRep`の出力や、`Compiler.RC2.DualABI`のworker/wrapperの合成を変更したときは、`tests/Test11DualABILeak.idr`に対して`valgrind --leak-check=full`でも検査する。
   このテストは、昇格するパラメータの値を、意図的に小整数キャッシュの範囲の外へ追いやる。
   そのため、`Main.fib`/`Main.sumTo`の再帰で起きたように、dropの欠落が何もしない処理に隠れることがない。
   期待する結果は、`definitely lost: 0 bytes in 0 blocks`である(`still reachable`として現れてよいのは、100エントリの不死の小整数キャッシュだけである)。
6. **Stage 4が実際に呼び出し箇所を書き換えるようになった後は、性能向上を直接確認する。**
   `time ./build/exec/<BenchFib output>`を数回実行し、同じファイルを本物の`idris2 --cg refc`でビルドしたものと比べる。
   `fib 30`(`tests/BenchFib.idr`)は、Stage 4が入るまでは、RefCと同等かやや遅かった(このプロジェクトの履歴の、それ以前のすべてのStageにおいて。`BENCHMARKS.md`を参照)。
   Stage 4が入ってからは、およそ**35%高速**になった。
   このパイプラインへの将来の変更で、これが再び同等に近づいた場合は、以前書き換えや昇格が行われていた呼び出し箇所で、それが行われなくなったという実際の兆候である。
   単なる誤差だと決めつける前に、`--directive dumprcexpr`と、生成されたCの直接の読み取り(上記のステップ2〜3)で調べる価値がある。
