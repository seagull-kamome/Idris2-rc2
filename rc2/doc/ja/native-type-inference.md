# ネイティブ型推論(`Compiler.RC2.Types`)

rc2のネイティブ(unboxed)表現機構に関する実装ノート。将来のセッション
が、設計を再導出したり、既に発見・修正済みのバグを再発見したりせず
に完全な文脈を取り戻せるようにするために書かれた。当初のStage 2-3
実装に加え、それに続く複数のリファクタリング・修正に対応する
(`git log`参照、`2026-08-12`付の「reduce unnecessary variable/
statement generation」「ROp's operand-drop」「elide dup/drop for
always-tagged PrimTypes」、`2026-08-13`付の比較/分岐融合の各コミット)。
本書の機構が連携する姉妹のIRレベルパスについては`doc/reuse-analysis.md`
も参照(どちらも同じ`natives`集合を参照する)。

(原文: `doc/native-type-inference.md`。内容が乖離した場合は原文を正とする。)

## 問題

Idris2自身のコンパイル済みIR(`Lifted`)はあらゆる値を一様にBoxedな
`IDRIS2RC2_Value*`として表現する -- `x * x + 1`のような算術チェイン
は、そのままだとRefCが実際にそうしているように、中間結果ごとに
新しいヒープセルを確保し参照カウント管理することになる。rc2の
ネイティブ型推論は、*関数ローカル*な数値中間値についてはこれを
完全にスキップできるようにする: それらは1つの関数本体の中にいる
限り、ヒープ確保も参照カウントのトラフィックもなしに、生のCスカラー
(`int64_t`、`double`、...)としてスタック上に生きる。

**意図的なスコープの境界**(`TODO.md`の「Scope」節参照): これが
適用されるのは、数値`PrimFn`またはリテラルから直接来る`RLet`束縛
された中間値のみ。関数の*引数*と*戻り値*は無条件にBoxedのまま
-- 呼び出し規約そのものは変更していない(デュアルなネイティブ/Boxed
ABIはない。これが残っている最大のレバーであり、`TODO.md`の
「Performance」節で別途追跡している)。`Integer`(GMP)と`String`は
文脈に関わらず一切ネイティブ対象にならない。

## 決定がどこで下され、どこに保存されるか

再利用パス(Phase 1+2の後に実行される独立した木の書き換えパス)とは
異なり、ネイティブかBoxedかは`RC.idr`のPhase 1(`normalize`/
`bindCompound`)の最中に**インライン**で、束縛される値に対して
`Types.repOf`を呼び出すことで決定され、その結果は`RLet`ノード自身
の`Rep`フィールド(`RBoxed | RNative PrimType`、`RCExp.idr`)に直接
保存される。この決定自体のための独立した全木解析パスも、サイド
テーブルも存在しない -- `Emit.idr`の`RepMap`は各`RLet`が*発行される*
際に逐次的に埋められるが、これは単に、後からの*使用*箇所(裸の
`RCLocal`のIDしか持たず、決定を下したノード自体は持たない)が既に
下された決定を引けるようにするためであり、決定が下される場所では
ない。

### `Types.idr`の決定関数群

- `nativeEligible : PrimType -> Bool` -- 対象となる集合: `Int`、
  `Int8`/`16`/`32`/`64`、`Bits8`/`16`/`32`/`64`、`Double`、`Char`。
  注目すべきは`Integer`/`String`が*含まれない*こと。
- `opResultRep : PrimFn arity -> Maybe PrimType` -- ある`PrimFn`の
  結果がネイティブ対応の場合に持つはずの`Rep`。算術/ビット演算の
  すべてと`Double*`系の数学関数のすべてがカバーされている。比較
  (`LT`/`GT`/`EQ`/`LTE`/`GTE`)は**意図的にここに含まれていない**
  (下記「比較は別の仕組み」参照)。
  `Cast i o`は両方の型が必要になる唯一のケース: 結果がネイティブに
  なるのは`i`と`o`の*両方*がネイティブ対応の場合のみ
  (`nativeEligible i && ifNative o`) -- ネイティブ対応でないソース
  (GMPの`Integer`、`String`)からのキャストは、たとえ*変換先*の型
  自体がネイティブ対応であっても、常にBoxedな`idris2rc2_cast_*`
  経路のままでなければならない。そもそも読み取るべきソース値の
  ネイティブ表現が存在しないため。
- `opArgTyFor : PrimType -> PrimFn arity -> PrimType` -- 特定の演算
  について、その(既に決定済みの)結果型`ty`が与えられたときの
  オペランド型。`Cast`を除くすべての演算は、結果と全オペランドで
  `ty`を共有する。`Cast`だけは例外で、その唯一の引数の型は演算
  自身のソース型`i`であり、結果型`o`ではない。`RC.idr`(どの
  Boxedオペランドが`alwaysUnboxed`かを決める)と`Emit.idr`
  (各オペランドのレンダリング/unbox)で共有されており、この
  対応関係の定義を1箇所に保ち、手で2箇所を同期させずに済ませて
  いる。
- `litRep : Constant -> Maybe PrimType` -- どの数値リテラルの
  `Constant`種別がネイティブ対応かを示す。`RC.idr`の`bindOne`
  (あるオペランドがそもそも`RCConst`を必要とするかどうかの判定 --
  下記参照)と`Emit.idr`の`repOfLocal`で共有されている。
- `repOf : RCExp -> Maybe PrimType` -- `RC.idr`が各`RLet`/
  `bindCompound`箇所で実際に呼び出すエントリポイント。`ROp`/
  `RPrimVal`だけが`Native`を提案しうる。裸の変数の素通し(または
  それ以外の何でも)は`Boxed`のまま。*合成*`RLet`の連なり
  (Phase 1自身のANF正規化は、オペランドが既に単なる変数でない
  場合、例えば`d * 2`のリテラル`2`のように、常にひとつ導入する)
  を透過して、その下にある実際の`ROp`/`RPrimVal`を見つける --
  **この透過処理自体が実際のバグの修正だった**(下記「発見した
  バグ」参照): これがないと、自分自身のオペランドの1つのために
  合成letでラップされた演算は、そもそもネイティブ対応として
  一切認識されなかった。
- `alwaysUnboxed : PrimType -> Bool` -- `nativeEligible`とは*別の*
  概念で、混同しやすい。rc2のランタイムは`Int8`/`16`/`32`、
  `Bits8`/`16`/`32`、`Char`を*無条件に*タグ付きポインタ
  (ペイロードをポインタ語自体に詰め込む、`support/rc2/datatypes.h`
  参照)として表現し、実際のヒープ確保は一切行わない -- (小整数
  キャッシュの外では確保が発生する)`Int`/`Int64`/`Bits64`や
  (常に確保する)`Double`とは異なる。これは*Boxed*な値(Cレベルでは
  依然`IDRIS2RC2_Value*`、例えば通常の関数引数)についての
  ランタイム表現上の事実であって、あるローカルが上記の
  ネイティブ扱いを受けたかどうかとは無関係 -- そのような値に対する
  `idris2rc2_dup`/`drop`/`free`はいずれにせよ無条件のno-opなので、
  呼び出しをそもそも生成すること自体が純粋な無駄になる。`RC.idr`の
  `alwaysUnboxedBoxedLocalsR`(下記「`natives`集合」参照)から参照
  される。
- `cmpArgTy : PrimFn arity -> Maybe PrimType` -- 比較/分岐融合
  (下記参照)と共に追加された。`LT`/`GT`/`EQ`/`LTE`/`GTE`に特化して
  共有オペランド型を取り出す。これらは`opResultRep`のエントリを
  自前で持たないためオペランド型の参照先が別途必要になる。

### `RCLocal.RCConst` -- リテラルは`RLet`を完全にスキップする

ネイティブ対応のリテラルオペランド(`litRep`がカバーするもの)は
そもそも`RLet`+`RPrimVal`のペアを一切持たない: `RC.idr`の`bindOne`
はその場で直接`RCConst c`(`RCExp.idr`の`RCLocal`型)を生成し、ID
の割り当ても合成束縛も行わない。`Emit.idr`はそれをどこで読まれても
インラインのリテラル式としてレンダリングする(`repOfLocal`/
`inlineExprFor`)。C宣言も`RepMap`/`InlineMap`の管理も一切不要。
所有権が推論される場所(`Owned`集合、`natives`集合、`RDup`/`RDrop`/
`RFree`の対象)はどこでも、`RCConst`をネイティブローカルと同様に
扱わなければならない: 除外され、一切触れられない(`RC.idr`の
`splitBorrows`の最初の節)。

## `natives`集合 -- 所有権解析(Phase 2)がどう一貫性を保つか

Phase 2(`annotate`)は*あらゆる*ローカルの*あらゆる*使用について、
それが参照カウントに一切参加しないかどうかを知る必要がある。
`annotateDef`が定義ごとに一度構築する`natives : SortedSet RCLocal`
集合(`definitionNatives`)に、あるローカルを入れる理由はまったく
異なる2つある:

1. **`nativeLocalsR`** -- 真に`RNative`なRepを持つ`RLet`束縛された
   ローカル(Phase 1自身の決定を木から歩いて取り出したもの)。参照
   カウントは一切なし。そもそもboxedでもない。
2. **`alwaysUnboxedBoxedLocalsR`** -- Boxedなローカル(典型的には
   関数引数)で、*型*がネイティブ演算自身のオペランド位置において
   `Types.alwaysUnboxed`であるもの。これらはCレベルでは実際に
   参照カウントを*持つ*が、それに対するあらゆる操作がいずれにせよ
   no-opになることが最初から分かっているので、(1)とは別の理由で
   除外される。

`natives`の全ての消費者(`splitBorrows`、`boxedOperands`、`RV`の
ケース、`RLet`の`owned'`/`dropDeadLet`、`annotateConAlt`)は両方を
同一に扱う: そのローカルがどう、あるいは何回使われようと、決して
dup/drop/freeしない。この二重の由来(と、全ての消費者が両方を
同じように扱わなければならないという要件)自体が、常時unboxed省略
作業の際に発見された実際のバグの修正である -- 下記参照。

## IRに保存されるもの vs. 発行時に再導出されるもの

このコードベース全体で意図的に繰り返されているアーキテクチャ上の
パターン: **Phase 2が決定し、Emit.idrは下ろすだけ**。この決定を
発行まで、Emit.idrに再導出させることなく運ぶために存在する
フィールドが2つある:

- `RLet.Rep` -- Phase 1自身のネイティブ/Boxedの決定(Phase 2では
  ない、上記参照)だが、「一度決定してノードに保存する」という
  同じ原則。
- `ROp.postDrop : List RCLocal` -- ある演算が読み終えた時点で
  dropが必要な*Boxed*オペランド*すべて*、*出現*ごとに1エントリ
  (なので`x + x`は`x`を2回列挙する)。Phase 1は常にこれを`[]`
  として構築し、Phase 2の`annotate`が`boxedOperands natives
  (toList args)`経由で埋める -- 単純な「ネイティブでもRCConst
  でもない」フィルタであり、あるオペランドがこの演算に読まれる
  *前に*dupが必要だったかどうかを支配する`owned`/借用の帳簿付け
  (`splitBorrows`)とは独立している: 演算の読み取りは、その出現が
  move-in(owned)だったか借用のためにdupされたかに関わらず、
  Boxedな出現1回につきちょうど1回のdropを常に必要とする。dup
  (もしあれば)は、まさにその読み取りに消費させるための独自の
  参照を与えるために存在するから。

このフィールドはかつて存在せず、代わりに`Emit.idr`が発行時に
`keepBoxedLocals`というヘルパー(`emitRC`と`emitNativeValue`の
両方の`ROp`ケースから別々に呼ばれていた)を通して「自分のどの
オペランドがBoxedか」を独立に再導出していた -- `RCExp.idr`自身の
「Emitは純粋に機械的」という主張が実際には偽だった唯一の場所であり、
理論上は2つの独立した呼び出し箇所が食い違いうる状態だった。1つの
Phase 2で計算されるフィールドへ統合したのは、まさにこのリスクを
取り除くため(そして下記の常時unboxed省略作業に、2箇所ではなく
更新すべき単一の真実の源を与えるため)である。

## 発行(`Emit.idr`)

- `nativeCType : PrimType -> String` -- 生のC型(`int64_t`、
  `uint8_t`、`double`、...)。
- `nativeMk : PrimType -> String -> String` / `nativeUnbox : PrimType
  -> String -> String` -- ネイティブなC式を新しい`IDRIS2RC2_Value*`
  へbox化する / Boxedな値を生のC式までunbox化する
  (`idris2rc2_mkInt64(...)` / `idris2rc2_to_i64(...)`など) -- 値が
  2つの世界を行き来する境界(関数境界、コンストラクタフィールド、
  caseのスクルティニー)。
- `rcVarToNativeC`/`rcVarToBoxedC` -- `RCLocal`をそれぞれネイティブ
  またはBoxedなC式として読む。Rep対応(既にNativeなローカルは
  そのまま読まれ、Boxedなものはその場で`nativeUnbox`される。
  `RCConst`/`InlineMap`されたローカルはそのリテラル/式のテキストを
  インライン化し、`var_N`は一切宣言されない)。それ自体では
  dup/dropを一切行わない -- ある*使用*が必要とした参照カウントの
  調整は、木のより前の位置で既に明示的なラップする`RDup`/`RDrop`/
  `RFree`ノードとして作られている(`ROp`の`postDrop`だけが例外で、
  自分自身の注釈を運ぶ)。
- `cOp`(Boxedな結果を返す演算。Boxedランタイム関数を呼ぶ、例えば
  新しい`IDRIS2RC2_Value*`を返す`idris2rc2_add_Int64(x, y)`)対
  `nativeOpExpr`(ネイティブな結果を返す演算。確保を一切伴わない
  生のC式、例えば`(x + y)`) -- 同じ`PrimFn`の空間に対する2種類の
  レンダラーで、`Types.opResultRep`がその演算の結果はここでは
  ネイティブだと言ったかどうかで選ばれる。
- `emitNativeValue` -- `emitRC`のネイティブ型版で、`ROp`/`RPrimVal`
  をラップする`RLet`/`RDup`/`RDrop`/`RFree`の連なりを歩いて生のC式
  文字列(に加え、実際にその式を使った*後で*呼び出し元が発行しな
  ければならない、保留中のBoxedオペランドのdropたち)を生成する
  (なぜこの関数自身ではなく呼び出し元が発行しなければならないかは
  下記「postDropの発行順序に関するバグ」参照)。
- `InlineMap` / `tryInlineNativeOp` -- Native/Boxedの基本的な区分の
  上に乗るさらなる最適化: Boxedオペランドが**ゼロ**で、使用が
  **ちょうど1回**のネイティブ演算は、その式が`var_N`として宣言
  されることすら一切なく、その唯一の使用箇所へ直接埋め込まれる。
  Boxedオペランドがゼロであることが、読み取りを遅延させても常に
  安全である理由(途中で介在するdup/dropがその値を無効化する
  ことがない)。使用がちょうど1回であることが、再計算を防ぐ理由。
  裸のリテラルオペランドはこのカテゴリの最も一般的なメンバーで
  あり、同じテーブルの退化した一例として扱われる。

## 比較は別の、より狭い仕組み(`RCmpCase`)

比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)は`opResultRep`から目立って
**除外**されている -- 算術演算のように`RLet.Rep`をネイティブに
してもらうことは決してない。代わりに、ある比較がIdris2自身の
Bool表現(`False=0`/`True=1`)に対する二方向マッチの唯一かつ直接の
スクルティニーである場合、`RC.idr`の`normalize`はその形全体を
専用の`RCmpCase`IRノード(`tryFuseCompare`、`boolBranches`、
`constantBoolValue`)へ直接融合する -- 比較は生のCブール式となって
`if`へそのまま埋め込まれ、ネイティブかどうかを問わずBoxedな値が
一切実体化しない。これは本モジュールの上に(そして本モジュールの
`nativeEligible`を再利用しつつ)積み重ねられた別個の最適化であり、
`RLet.Rep`機構の拡張ではない -- 完全な設計とその自身のバグ
(`annotate`の`RCmpCase`ケースにおける二重解放。本書のどの内容とも
無関係)については`doc/`のコミット履歴/`BENCHMARKS.md`の
「比較/分岐融合」節参照。

## 発見・修正したバグ(時系列。コミットレベルの詳細は`git log`/`BENCHMARKS.md`参照)

1. **`Cast Integer Int`のメモリ破壊。** `opResultRep (Cast i o)`は
   元々`o`(変換先の型)しか見ておらず、`i`(ソースの型)を見て
   いなかった。GMP `Integer`(常にBoxed、任意精度)からネイティブ
   対応の変換先へのキャストが誤ってネイティブ対応として扱われ、
   ヒープポインタをそのまま`int64_t`として再解釈していた。
   `nativeEligible i`も要求するよう修正。
2. **合成letの不透明性。** `d * 2`はリテラル`2`を合成`RLet`
   (Phase 1のANF正規化は、自明に見えない全てのオペランドを一様に
   束縛する)で束縛し、実際の`ROp`をラップする。以前のバージョンの
   `repOf`/`emitNativeValue`はそのラッパーを透過できず、式全体の
   ネイティブ対応性を見逃していた。`repOf`(および対応する発行
   ロジック)が合成`RLet`の連なりを透過して実際の`ROp`/`RPrimVal`
   を見つけるよう修正した。
3. **ネイティブ結果演算におけるBoxedオペランドのリーク。**
   `annotate`の所有権解析は、ネイティブ結果になる`ROp`のオペランド
   にも、他の値と同じowned/borrowedの帳簿付けを適用し、最後の
   使用を「消費」として扱う。しかし`Emit.idr`の`emitNativeValue`
   には(`emitRC`のBoxed版`ROp`ケースとは異なり)対応するクリーン
   アップが一切なかった -- ネイティブなunbox抽出を通してのみ読ま
   れたBoxedオペランドは、呼び出しごとに参照が1つずつリークして
   いた。`Test6NativeInts.idr`で発見された。これが、`ROp.postDrop`
   (上記)が今まさに存在する理由であり、単一のPhase 2計算による
   フィールドを`emitRC`と`emitNativeValue`が同一に下ろすことで、
   2つの独立して手書きされたクリーンアップ箇所を作らないように
   している。
4. **postDropの発行順序に関するリグレッション**(バグ3を*修正して
   いる最中に*発見された。実際の修正が着地する前)。素朴な最初の
   試みは、`emitRC`自身のBoxed版`ROp`ケースと同じ相対位置に不足
   していたdrop呼び出しを追加しただけだった -- しかし
   `emitNativeValue`が返すのは*インラインの式文字列*であり、完全な
   文ではない。その式を実際に埋め込んだ文を発行するのは呼び出し元
   である。戻り値を受け取った直後にdropすると、その式を経由して
   実際に値を読む文の*前に*(Cの文として)dropが実行されてしまう
   -- 正真正銘のuse-after-freeである。64bit型(`Int64`/`Bits64`、
   実際にヒープ確保される表現)でのみ発現した。8/16/32bit型は
   dup/dropがno-opになる`alwaysUnboxed`タグ付きポインタ表現を
   使うため、そのビット幅ではこのバグは完全に隠されていた。
   呼び出し元(その式を読む文を実際に発行する側)が`postDrop`の
   ローカルをdropする責任を持ち、しかもその文を発行した*後*に
   のみ行う -- 式を生成する関数自身の内部では決して行わない、と
   修正した。これが`emitNativeValue`自身のドキュメントコメントが
   「ここではなく、呼び出し元」と明記している理由 -- 一度実際に
   作ってしまったバグの正確な形を記録しているのである。
5. **`keepBoxedLocals`の反転したフィルタ**(`postDrop`フィールド
   の導入より前、RDup/RFreeの作業と並行して発見)。フィルタの
   条件が逆だった: 「既に`RepMap`に登録されている(つまりlet
   束縛されている)」を除外していたが、本来の意図は真に`RNative`
   なRepのものだけを除外することだった -- let束縛された*Boxed*
   なローカルまで誤ってdropリストから除外されてしまい、リーク
   していた。`RepMap`のメンバーシップではなく`Rep`の値自体
   (`RNative _`のみ)でフィルタするよう修正。

## ファイル

- `rc2/src/Compiler/RC2/Types.idr` -- 上記の全ての純粋な決定関数。
- `rc2/src/Compiler/RC2/RC.idr` -- Phase 1(`repOf`を呼び出す
  `bindOne`/`bindCompound`)、Phase 2(`nativeLocalsR`、
  `alwaysUnboxedBoxedLocalsR`、`definitionNatives`、
  `splitBorrows`、`boxedOperands`、比較融合のサイドチャネル用
  `tryFuseCompare`)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `Rep`、`RLet.rep`、
  `ROp.postDrop`、`RCLocal.RCConst`、`RCmpCase`。
- `rc2/src/Compiler/RC2/Emit.idr` -- `nativeCType`/`nativeMk`/
  `nativeUnbox`、`rcVarToNativeC`/`rcVarToBoxedC`、`cOp`/
  `nativeOpExpr`/`nativeCmpExpr`、`emitNativeValue`、
  `InlineMap`/`tryInlineNativeOp`、`RepMap`。

## 検証方法

1. ビルド+回帰テストの基準線: `CLAUDE.md`の「Build & test」節を参照
   (`idris2 --build rc2.ipkg`、次に`tests/refc-suite/run.sh`、19/19を期待する)。
2. `tests/Test6NativeInts.idr`が、固定幅整数型8種すべて
   (符号あり/なし、全ビット幅)を同じ算術チェインを通して行使し、
   境界値でのラップアラウンドも含めて本家`idris2 --cg refc`の出力
   とバイト単位で差分比較する -- これがまさに上記のバグ3/4を発見
   したテストなので、この領域に触れる際は最初にこれを再実行する。
3. `tests/BenchChain.idr`の`poly`関数は、この機構全体がエンド
   ツーエンドで機能していることの標準的な実証である: 生成された
   Cのヒープ確保/dup/dropの回数を本家RefCのものと比較する
   (`BENCHMARKS.md`の「算術チェイン」節に正確な期待値がある --
   rc2は3回の確保/3回のdup/4回のdrop、対するRefCは8/6/16。ここが
   後退するとRefC側の数値へ向かってドリフトして見えるはず)。
4. 生成された`.c`を、特定の`PrimType`のネイティブC型
   (例えば`int8_t`)が`IDRIS2RC2_Value*`/`idris2rc2_mk*`にラップ
   されずに裸のスタック宣言変数として出現するかどうかでgrepし、
   特定のテストケースについて実際にunbox化が発火したことを確認
   する。
