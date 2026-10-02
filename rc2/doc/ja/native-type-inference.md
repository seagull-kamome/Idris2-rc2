# ネイティブ型推論(`Compiler.RC2.Types`)

(原文: `doc/native-type-inference.md`。内容が乖離した場合は原文を正とする。)

rc2 のネイティブ(アンボックス)表現を実現する仕組みの実装ノート。将来のセ
ッションが、設計を導き直したり、すでに見つけて直したバグをもう一度見つけ
直したりせずに、全体の文脈を取り戻せるように書いてある。当初の Stage 2〜3
の実装に加え、その後のリファクタリングと修正も対象とする(`git log` を参
照。`2026-08-12` 付の「reduce unnecessary variable/statement generation」
「ROp's operand-drop」「elide dup/drop for always-tagged PrimTypes」と、
`2026-08-13` 付の比較/分岐融合のコミットである)。本書の仕組みと相互に作用
する、IR レベルのもう一方のパスについては `doc/reuse-analysis.md` を参照
(どちらも同じ `natives` 集合を参照する)。

## 問題

Idris2 自身のコンパイル済み IR(`Lifted`)は、すべての値を一様に、ボック
ス化された `IDRIS2RC2_Value*` として表現する。そのままでは、`x * x + 1`
のような算術の連鎖で、中間結果のたびに新しいヒープセルを確保し、参照カウ
ントで管理することになる。RefC は実際にそうしている。rc2 のネイティブ型推
論は、*関数ローカル*な数値の中間値についてこれを省く。そうした値は、1つ
の関数本体の中にとどまるかぎり、生の C スカラー(`int64_t`、`double`、
...)としてスタック上に置かれ、ヒープ確保も参照カウントの操作も発生しな
い。

**意図的なスコープの境界**(`TODO.md` の「Scope」節を参照): 対象は、数値の
`PrimFn` かリテラルから直接得られる、`RLet` 束縛の中間値だけである。関数
の*引数*と*戻り値*は、無条件にボックス化されたままになる。呼び出し規約自
体は変えていない(ネイティブ/ボックス化の二重 ABI はない。これは残された
最大の改善手段であり、`TODO.md` の「Performance」節で別に管理している)。
`Integer`(GMP)と `String` は、文脈にかかわらずネイティブ化の対象になら
ない。

## 決定を下す場所と保存する場所

再利用パス(フェーズ1+2のあとに走る、独立した木の書き換えパス)と違い、
ネイティブかボックス化かは、`RC.idr` のフェーズ1(`normalize`/
`bindCompound`)の最中に**インラインで**決まる。束縛される値に
`Types.repOf` を呼び、その結果を `RLet` ノード自身の `Rep` フィールド
(`RBoxed | RNative PrimType`、`RCExp.idr`)へ直接保存する。この決定のため
の独立した木全体の解析パスも、サイドテーブルもない。`Emit.idr` の `RepMap`
は、各 `RLet` を*出力する*ときに少しずつ埋められる。しかしこれは、後続の
*使用*箇所(素の `RCLocal` の id しか持たず、決定を下したノードは持たな
い)が、すでに下された決定を引けるようにするためにすぎない。決定が下され
る場所は `RepMap` ではない。

### `Types.idr` の決定関数

- `nativeEligible : PrimType -> Bool`: 対象になる集合は `Int`、
  `Int8`/`16`/`32`/`64`、`Bits8`/`16`/`32`/`64`、`Double`、`Char` である。
  `Integer`/`String` を含まない点に注意する。
- `opResultRep : PrimFn arity -> Maybe PrimType`: ある `PrimFn` の結果が
  ネイティブ化の対象になる場合の `Rep`。算術/ビット演算のすべてと、
  `Double*` の数学関数のすべてを網羅している。比較(`LT`/`GT`/`EQ`/
  `LTE`/`GTE`)は**意図的にここにない**(下の「比較は別の、より限定された
  仕組み」を参照)。`Cast i o` は、2つの型の両方を見る必要がある唯一のケー
  スである。結果がネイティブになるのは、`i` と `o` の*両方*がネイティブ化
  の対象のときに限る(`nativeEligible i && ifNative o`)。ネイティブ化の対
  象でない変換元(GMP の `Integer`、`String`)からの変換は、変換先の型がネ
  イティブ化の対象であっても、ボックス化された `idris2rc2_cast_*` の経路
  に残さなければならない。そもそも、読み出せる変換元のネイティブ表現が存
  在しないからである。
- `opArgTyFor : PrimType -> PrimFn arity -> PrimType`: 特定の演算のオペラ
  ンドの型。その演算自身の(すでに決まっている)結果型 `ty` を与えて求め
  る。どの演算も、結果とすべてのオペランドで `ty` を共有する。例外は
  `Cast` で、その唯一の引数の型は結果型 `o` ではなく、演算自身の変換元の
  型 `i` である。この関数は `RC.idr`(どのボックス化オペランドが
  `alwaysUnboxed` かの判定)と `Emit.idr`(各オペランドの出力とアンボック
  ス)で共有される。この対応関係の定義が、手作業で同期する2つではなく1つ
  になるようにするためである。
- `litRep : Constant -> Maybe PrimType`: どの種類の数値リテラルの
  `Constant` がネイティブ化の対象かを返す。`RC.idr` の `bindOne`(オペラン
  ドにそもそも `RCConst` が必要かどうかの判定。下記参照)と `Emit.idr` の
  `repOfLocal` で共有される。
- `repOf : RCExp -> Maybe PrimType`: `RC.idr` が `RLet`/`bindCompound` の
  すべての箇所で呼ぶ、実際の入口である。`Native` を提案するのは
  `ROp`/`RPrimVal` だけで、素の変数の素通し(やそれ以外のもの)は `Boxed`
  のままになる。*合成された* `RLet` の連鎖を通り抜けて、その下にある本物
  の `ROp`/`RPrimVal` を見つける。フェーズ1自身の ANF 正規化は、オペラン
  ドが単なる変数でないたびに、合成された `RLet` を1つ導入する(たとえば
  `d * 2` のリテラル `2`)。**この通り抜けは、それ自体が実際のバグの修正だ
  った**(下の「見つかったバグと修正」を参照)。これがないと、自分のオペラ
  ンドの1つのために合成された `let` で包まれた演算が、ネイティブ化の対象
  と認識されなくなる。
- `alwaysUnboxed : PrimType -> Bool`: `nativeEligible` とは*別の*概念であ
  り、取り違えやすい。rc2 のランタイムは、`Int8`/`16`/`32`、
  `Bits8`/`16`/`32`、`Char` を、常にタグ付きポインタとして表現する(ペイ
  ロードをポインタのワード自体に詰める。`support/rc2/datatypes.h` を参
  照)。実際のヒープ確保は決して行わない。`Int`/`Int64`/`Bits64`(小さな整
  数のキャッシュの外では確保する)や `Double`(常に確保する)とは異なる。
  これは*ボックス化された*値(C のレベルでは依然として
  `IDRIS2RC2_Value*`。たとえば通常の関数引数)についてのランタイム表現上
  の事実であり、*ローカル*変数が上記のネイティブ扱いを受けたかどうかとは
  関係がない。このような値に対する `idris2rc2_dup`/`drop`/`free` は、どの
  みち無条件で何もしない。そのため、呼び出しを生成すること自体が無駄であ
  る。`RC.idr` の `alwaysUnboxedBoxedLocalsR` が参照する(下の「`natives`
  集合」を参照)。
- `cmpOpTy : CmpOp -> PrimType`(`RCExp.idr`): 比較/分岐融合(下記)と同
  時に追加された。`LT`/`GT`/`EQ`/`LTE`/`GTE` に共通するオペランド型であ
  る。この5つ自体には `opResultRep` のエントリがない。`CmpOp` は演算と、
  消去された `IsCmp` の証明を対にしたものなので、`RCmpCase` が保持できる
  のはこの5つのどれかに限られる。

### `RCLocal.RCConst`: リテラルは `RLet` を経由しない

ネイティブ化の対象になるリテラルのオペランド(`litRep` が対象とするもの)
には、`RLet`+`RPrimVal` の組が一切作られない。`RC.idr` の `bindOne` がそ
の場で `RCConst c`(`RCExp.idr` の `RCLocal` 型)を直接作り、id の割り当て
も合成束縛も行わない。`Emit.idr` は、読まれる場所ごとにこれをインラインの
リテラル式として出力する(`repOfLocal`/`inlineExprFor`)。C の宣言も、
`RepMap`/`InlineMap` の帳簿も要らない。所有権を扱うあらゆる場所(`Owned`
集合、`natives` 集合、`RDup`/`RDrop`/`RFree` の対象)では、`RCConst` をネ
イティブなローカル変数と同じに扱わなければならない。つまり除外し、決して
触らない(`RC.idr` の `splitBorrows` の最初の節)。

## `natives` 集合: 所有権解析(フェーズ2)の一貫性の保ち方

フェーズ2(`annotate`)は、*すべての*ローカル変数の*すべての*使用につい
て、それが参照カウントにそもそも関わるかどうかを知る必要がある。
`annotateDef` が定義ごとに1度作る `natives : SortedSet RCLocal` の集合
(`definitionNatives`)には、まったく別の2つの理由でローカル変数が入る。

1. **`nativeLocalsR`**: 本当に `RNative` の `Rep` を持つ、`RLet` 束縛の
   ローカル変数(フェーズ1自身の決定を、木から読み戻したもの)。参照カウ
   ントがまったくなく、ボックス化もされていない。
2. **`alwaysUnboxedBoxedLocalsR`**: ネイティブな演算自身のオペランド位置
   で、*型*が `Types.alwaysUnboxed` であるボックス化のローカル変数(典型
   的には関数引数)。これらは C のレベルでは参照カウントを*持つ*が、それ
   に対する操作はどれも何もしないはずだったので、(1)とは別の理由で除外
   される。

`natives` を使うすべての箇所(`splitBorrows`、`boxedOperands`、`RV` のケ
ース、`RLet` の `owned'`/`dropDeadLet`、`annotateConAlt`)は、この2つを同
一に扱う。ローカル変数がどのように、何回使われても、dup/drop/free は行わ
ない。入口が2つあること、そしてすべての使用箇所が両者を同じに扱わなけれ
ばならないことによって、always-unboxed の省略は新しい判定ロジックを足さずに
入った。のちに、これを見落とした2つのラッパー生成経路があった(下の「見つ
かったバグと修正」の 6 を参照)。

## IR に保存するものと、出力時に導き直すもの

このコードベースには、繰り返し現れる設計上のパターンがある。**フェーズ2が
決め、Emit.idr は低水準化だけを行う**というものである。フェーズ2の決定を
`Emit.idr` に導き直させずに出力まで届けるため、2つのフィールドを用意して
いる。

- `RLet.Rep`: フェーズ1自身の、ネイティブかボックス化かの決定(フェーズ2
  ではない。上を参照)。ただし「一度だけ決めてノードに保存する」という原
  則は同じである。
- `ROp.postDrop : List RCLocal`: 演算が読み終えたあとに drop しなければ
  ならない、*すべての*ボックス化オペランド。*出現*ごとに1エントリなの
  で、`x + x` は `x` を2回並べる。フェーズ1は常にこれを `[]` として作
  る。フェーズ2の `annotate` が `boxedOperands natives (toList args)` で
  埋める。これは「ネイティブでも `RCConst` でもない」ものを単純に拾うフィ
  ルタであり、演算がオペランドを読む前に *dup* が必要だったかどうかを決
  める `owned`/借用の帳簿(`splitBorrows`)からは独立している。演算が読む
  たびに、ボックス化されたオペランドの出現1つにつき、ちょうど1回の drop
  が必要になる。その出現が(所有された状態で)移動してきたものでも、借用
  のために dup されたものでも同じである。dup があるとすれば、それは読み出
  しに、消費するための自分の参照を与えるためだからである。

このフィールドは、以前は*存在しなかった*。`Emit.idr` が出力時に、
`keepBoxedLocals` というヘルパーで「自分のオペランドのうちボックス化され
ているものはどれか」を独立に導き直していた。このヘルパーは、`emitRC` と
`emitNativeValue` の `ROp` のケースが別々に呼んでいた。独立した2つの呼び
出し箇所が原理的には食い違いうるため、ここは、`RCExp.idr` 自身の「Emit は
純粋に機械的である」という主張が実際には成り立たなかった唯一の箇所だっ
た。この危険をなくし、あわせて後述の always-unboxed の省略のために更新す
べき真実の源を2つではなく1つにするため、フェーズ2が計算する単一のフィー
ルドへ移した。

## 出力(`Emit.idr`)

- `nativeCType : PrimType -> String`: 生の C の型(`int64_t`、`uint8_t`、
  `double`、...)。
- `nativeMk : PrimType -> String -> String` / `nativeUnbox : PrimType ->
  String -> String`: ネイティブな C 式を新しい `IDRIS2RC2_Value*` にボッ
  クス化する関数と、ボックス化された値を生の C 式へアンボックスする関数
  (`idris2rc2_mkInt64(...)` / `idris2rc2_to_i64(...)` など)。値が2つの世
  界を行き来する境目(関数境界、コンストラクタのフィールド、case の判別対
  象)で使われる。
- `rcVarToNativeC`/`rcVarToBoxedC`: `RCLocal` を、それぞれネイティブな C
  式、ボックス化された C 式として読む。どちらも `Rep` を見て振る舞いを変
  える。すでにネイティブなローカル変数はそのまま読み、ボックス化されたも
  のはその場で `nativeUnbox` する。`RCConst` や `InlineMap` に入っている
  ローカル変数は、リテラルや式のテキストをインライン展開し、そのための
  `var_N` を宣言することはない。これらは自分では dup/drop を行わない。
  *使用*のために必要だった参照カウントの調整は、木のもっと前の段階で、包
  む `RDup`/`RDrop`/`RFree` ノードとして明示済みである(例外は `ROp` の
  `postDrop` で、これは自分の注釈を持つ)。
- `cOp`(結果がボックス化される演算。ボックス化版のランタイム関数を呼ぶ。
  たとえば `idris2rc2_add_Int64(x, y)` は新しい `IDRIS2RC2_Value*` を返
  す)と `nativeOpExpr`(結果がネイティブな演算。生の C 式で、たとえば
  `(x + y)` は確保を一切伴わない): 同じ `PrimFn` の空間に対する2つの出力
  器であり、`Types.opResultRep` がこの演算の結果をここでネイティブと判定
  したかどうかで使い分ける。
- `emitNativeValue`: `emitRC` に対応する、ネイティブ型版である。
  `ROp`/`RPrimVal` を包む `RLet`/`RDup`/`RDrop`/`RFree` の連鎖をたどり、
  生の C 式の文字列を作る。あわせて、保留中のボックス化オペランドの drop
  も返す。これは、その式を実際に使ったあとで*呼び出し側*が出力しなければ
  ならない。この関数自身が出力してはいけない理由は、下の「postDrop の順序
  の退行」を参照。
- `InlineMap` / `tryInlineNativeOp`: ネイティブとボックス化という基本の区
  分の上に重ねた、さらなる最適化である。ボックス化オペランドを**1つも**持
  たず、**ちょうど1回**だけ使われるネイティブな演算は、`var_N` として宣言
  されることなく、式がその1つの使用箇所へ直接展開される。ボックス化オペ
  ランドがないことが、読み出しの先送りを常に安全にする(途中のどこかの
  dup/drop によって無効になるものがない)。使用がちょうど1回であること
  が、再計算を避ける。素のリテラルのオペランドはこの分類に最も多く当ては
  まり、同じ表の退化したケースとして扱われる。

## 比較は別の、より限定された仕組み(`RCmpCase`)

比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)は `opResultRep` に**ない**ことが目立
つ。算術のようにネイティブな `RLet.Rep` を持つことはない。代わりに、比較
が、Idris2 自身の Bool の符号化(`False=0`/`True=1`)に対する二分岐の、唯
一かつ直接の判別対象になっているとき、`RC.idr` の `normalize` がその形全
体を専用の `RCmpCase` IR ノードへ融合する(`tryFuseCompare`、
`boolBranches`、`constantBoolValue`)。比較は生の C のブール式になって
`if` に直接埋め込まれ、ネイティブであれ何であれ、ボックス化された値が実
体化されることは一切ない。これは、このモジュールの上に重ねた(そして
`nativeEligible` を再利用する)別個の最適化であり、`RLet.Rep` の仕組みの
拡張ではない。設計の全体と、そのバグ(`annotate` の `RCmpCase` のケースに
あった二重解放で、本書の内容とは無関係)については、`doc/` のコミット履歴
と `BENCHMARKS.md` の「比較/分岐融合」節を参照。

## 見つかったバグと修正(時系列。コミット単位の詳細は `git log` と `BENCHMARKS.md` を参照)

1. **`Cast Integer Int` でのメモリ破壊。** `opResultRep (Cast i o)` は当
   初、`o`(変換先の型)だけを調べ、`i`(変換元の型)を調べていなかった。
   GMP の `Integer`(常にボックス化される、任意精度の型)からネイティブ化
   の対象の型への変換が、誤ってネイティブ化の対象と扱われ、ヒープのポイ
   ンタを生の `int64_t` として解釈してしまった。`nativeEligible i` も要
   求することで修正した。
2. **合成された let による不透明化。** `d * 2` は、リテラル `2` を、本物
   の `ROp` を包む合成された `RLet` に束縛する(フェーズ1の ANF 正規化
   は、自明に見えない*すべての*オペランドを一様に束縛する)。`repOf` と
   `emitNativeValue` の初期版はこの包みを見通せず、式全体がネイティブ化の
   対象であることを見逃した。`repOf`(と、それに対応する出力のロジック)
   が合成された `RLet` の連鎖を通り抜けて、本物の `ROp`/`RPrimVal` を見つ
   けるようにして修正した。
3. **ネイティブな結果を返す演算でのボックス化オペランドのリーク。**
   `annotate` の所有権解析は、ネイティブな結果を返す `ROp` のオペランドに
   も、ほかの値と同じ所有/借用の帳簿を適用し、最後の使用を「消費された」
   と扱う。ところが `Emit.idr` の `emitNativeValue` には(`emitRC` のボッ
   クス化された `ROp` のケースと違って)対応する後始末がまったくなかっ
   た。ネイティブへのアンボックス抽出でしか読まれないボックス化オペラン
   ドは、呼び出しのたびに参照を1つリークした。`Test112Numeric/NativeInts.idr`
   で見つかった。`ROp.postDrop`(上記)は、まさにこの誤りが二度と起きな
   いようにするために存在する。`emitRC` と `emitNativeValue` が同一に低水
   準化する、フェーズ2が計算する単一のフィールドであり、独立に手書きされ
   た2つの後始末の箇所ではない。
4. **postDrop の順序の退行**(バグ3を直している*最中*、本来の修正を入れ
   る前に見つかった)。最初の素朴な試みでは、不足していた drop 呼び出しを
   `emitRC` のボックス化された `ROp` のケースと同じ相対位置に追加した。し
   かし `emitNativeValue` が返すのは完全な文ではなく、*インライン式の文字
   列*である。その式を埋め込んだ文を実際に出力するのは呼び出し側である。
   戻った直後に drop すると、その式で値を実際に読む文より*前に*、(C の文
   として)drop が実行されてしまう。これは本物の use-after-free である。
   見えるのは64ビット型(`Int64`/`Bits64`。実際にヒープを確保する)だけ
   で、8/16/32ビット型は `alwaysUnboxed` のタグ付きポインタ表現を使い、
   dup/drop が何もしないため、これらの幅ではバグが完全に隠れる。修正は、
   式を読む文を実際に出力する側(呼び出し側)に `postDrop` のローカル変数
   の drop を担わせ、しかもその文を出力した*後*にだけ行うことである。式を
   作る関数自身の中では決して行わない。`emitNativeValue` 自身のドキュメン
   トコメントが「ここではなく呼び出し側で」と明記しているのはこのためで、
   一度起きたバグの正確な形を記録している。
5. **`keepBoxedLocals` のフィルタの反転**(`postDrop` フィールドの導入よ
   り前からあり、RDup/RFree の作業と並行して発見された)。フィルタの条件
   が逆だった。本来は本当に `RNative` の `Rep` を持つものだけを除外するつ
   もりだったのに、「`RepMap` に登録済み(つまり let 束縛されている)」も
   のを除外していた。そのため、let 束縛された*ボックス化*のローカル変数も
   drop のリストから誤って除外され、リークしていた。`RepMap` に含まれる
   かどうかではなく、`Rep` の値そのもの(`RNative _` のみ)でフィルタする
   ように修正した。
6. **`alwaysUnboxed` の省略を、その後に追加された2つのラッパー生成経路が
   見落としていた。** この省略は、本書を最初に書いた時点から `RC.idr` の
   `annotate` パスに組み込まれていた。上記の仕組みに欠陥があったわけでは
   ない。`Types.alwaysUnboxed` 自体も、`annotate` からの参照
   (`alwaysUnboxedBoxedLocalsR`。上の「`natives` 集合」を参照)も、最初か
   ら正しかった。ところが、その数日後に追加された二重 ABI 関連の2つのコー
   ド経路は、それぞれ独自に、常にボックス化されるラッパー関数を合成してい
   ながら、この省略を参照していなかった。

   (1) `Compiler.RC2.DualABI` の `synthesizeWorker`(Stage 3a。二重 ABI
   の対象となる通常の関数が書き換えられて得る、常にボックス化されるラッパ
   ー)。その `wrapperPostDrop` は、ネイティブに昇格したすべてのパラメー
   タを、`PrimType` に関係なく無条件に drop していた。(2)
   `Compiler.RC2.Emit` の `emitGenericForeignWrapper`(通常の `%foreign`
   宣言のための、常にボックス化される C のラッパースタブ)。その
   `removeVarsArgList` は、FFI の引数をすべて変数名だけで drop してお
   り、drop するかどうかの判断の前に、引数自身の `CFType` が捨てられてい
   た。

   どちらも正しさのバグではなかった。`alwaysUnboxed` の値に対する
   `idris2rc2_drop` は、構成上、ランタイムで何もしないことが保証されてい
   る(上の `alwaysUnboxed` の項目を参照)。そのため、出力された C は誤った
   ものではなく、無駄なものだっただけである。ただし、この2つの経路に限っ
   ては、`alwaysUnboxed` が存在する意義そのものを損なっていた。

   修正は、どちらも `Types.alwaysUnboxed` で直接フィルタすることである。
   `DualABI.idr` の `wrapperPostDrop` は、自身の
   `eligible : List (Int, PrimType)` を `alwaysUnboxed` でフィルタし、
   drop のリストには always-unboxed でない位置だけを残す。`Emit.idr` に
   は共有のヘルパー
   `alwaysUnboxedDropVar : (String, String, CFType) -> Maybe String` を
   追加した。これは `createFFIArgList`/`discardLastArgument` と同じ
   `where` ブロックにあり、`emitGenericForeignWrapper` と
   `emitFastPackFixedWrapper` の両方の `removeVarsArgList` が使う(後者
   は一貫性のためだけである。`idris2rc2_fastPackFixed`/
   `idris2rc2_fastConcatFixed` の引数は常に `CFUser` なので、実際には
   `alwaysUnboxed` のケースに当たらない)。このヘルパーは、`cfTypeNative
   vt` が `Just ty` で、かつ `alwaysUnboxed ty` が成り立つとき、
   `Nothing`(drop を省く)を返す。

   関連する3つ目の箇所である `Emit.idr` の `emitFFIWorker`(Stage 3c の
   ネイティブ ABI の FFI ワーカーで、常にボックス化されるラッパーではな
   い)も調べたが、修正は不要だった。そのボックス化の位置は、構成上、
   `cfTypeNative` がすでに `Nothing` を返した(そもそもネイティブ化の対象
   でない)位置とちょうど一致する。一方 `cfTypeNative` は、`alwaysUnboxed`
   の型に対して必ず `Just` を返す。したがって、そのような型がこのワーカー
   自身のボックス化位置の drop リストに現れることは、構造上ありえない。

## ファイル

- `rc2/src/Compiler/RC2/Types.idr`: 上で説明した、純粋な決定関数のすべ
  て。
- `rc2/src/Compiler/RC2/RC.idr`: フェーズ1(`repOf` を呼ぶ
  `bindOne`/`bindCompound`)と、フェーズ2(`nativeLocalsR`、
  `alwaysUnboxedBoxedLocalsR`、`definitionNatives`、`splitBorrows`、
  `boxedOperands`)。比較融合の別経路である `tryFuseCompare` もここにあ
  る。
- `rc2/src/Compiler/RC2/RCExp.idr`: `Rep`、`RLet.rep`、`ROp.postDrop`、
  `RCLocal.RCConst`、`RCmpCase`。
- `rc2/src/Compiler/RC2/Emit.idr`: `nativeCType`/`nativeMk`/
  `nativeUnbox`、`rcVarToNativeC`/`rcVarToBoxedC`、`cOp`/`nativeOpExpr`/
  `nativeCmpExpr`、`emitNativeValue`、`InlineMap`/`tryInlineNativeOp`、
  `RepMap`。あわせて `alwaysUnboxedDropVar`(上のバグ6)もあり、
  `emitGenericForeignWrapper`/`emitFastPackFixedWrapper` の
  `removeVarsArgList` が参照する。
- `rc2/src/Compiler/RC2/DualABI.idr`: 本書のフェーズ1/2の仕組みの一部では
  ないが、`synthesizeWorker` の `wrapperPostDrop` が、`Types.alwaysUnboxed`
  の2つ目の、独立した利用者である(上のバグ6)。通常の関数に対する
  `annotate` の `alwaysUnboxedBoxedLocalsR` と同じやり方で、二重 ABI のラ
  ッパーの drop リストをフィルタする。

## 検証方法

1. ビルドと回帰のベースライン: `CLAUDE.md` の「Build & test」節を参照す
   る(`idris2 --build rc2.ipkg` のあと、`tests/refc-suite/run.sh` を実行
   し、19/19 を期待する)。
2. `tests/Test112Numeric/NativeInts.idr` は、符号付き/符号なしのあらゆる
   幅の、8種類の固定幅整数型すべてを、同じ算術の連鎖に通す。出力は、境界
   値でのラップアラウンドを含めて、本物の `idris2 --cg refc` の出力とバイ
   ト単位で比較される。上のバグ3/4を見つけたのはこのテストであり、この領
   域に手を入れるときは最初にこれを再実行する。
3. `tests/BenchChain.idr` の `poly` 関数は、仕組み全体がエンドツーエンド
   で機能することを示す標準的なデモである。生成された C のヒープ確保/
   dup/drop の回数を、RefC のものと比べる(期待される正確な数値は
   `BENCHMARKS.md` の「算術チェイン」節を参照。確保3/dup 3/drop 4 が rc2、
   8/6/16 が RefC である。ここでの退行は、これらの数値が RefC の値へ戻っ
   ていくという形で現れるはずである)。
4. 生成された `.c` を grep して、特定の PrimType のネイティブな C の型
   (たとえば `int8_t`)が、`IDRIS2RC2_Value*`/`idris2rc2_mk*` で包まれ
   ず、スタック上の素の変数として宣言されていることを確かめる。これによ
   って、あるテストケースでアンボックスが実際に働いたことを確認できる。
5. 上のバグ6(`alwaysUnboxed` を見落とした、二重 ABI のラッパーの2つの経
   路)には、独立した回帰の確認がある。どちらの経路も、上の
   `Test112Numeric/NativeInts.idr` が検証するために書かれた `RC.idr` の
   `annotate` パスからは到達できないためである。
   `tests/build/Test112Numeric_rc2.c` の `Main_chainInt8`/`chainInt16`/
   `chainInt32`(と Bits8/16/32 の対応するもの)を手作業で確認し、二重
   ABI のラッパーが引数に対して `idris2rc2_drop` をまったく呼ばなくなっ
   たことを確かめる。一方 `Main_chainInt64`(ネイティブ化の対象だが
   `alwaysUnboxed` ではない。小さな整数のキャッシュの外では本物のヒープ
   確保になる)は、2つの引数を従来どおり正しく drop している。同様に、
   `tests/build/Test27FFIDualABI_rc2.c` の `Main_prim__bumpChar`
   (`CFChar`/`Char` の `%foreign` ラッパー)は引数を drop しなくなり、
   `Main_prim__mixed`(`Int`+`String`。どちらも `alwaysUnboxed` でな
   い)と `Main_prim__noop` は従来どおり正しく drop する。
   `verify.sh --regen-expected` の全件(85/85)と `refc-suite/run.sh`
   (19/19)がどちらも通っており、これが動作の変更を伴わない、純粋に生成
   コードの無駄の修正であることと整合する。
