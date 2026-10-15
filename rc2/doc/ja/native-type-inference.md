# ネイティブ型推論(`Compiler.RC2.Types`)

(原文: `doc/native-type-inference.md`。内容が乖離した場合は原文を正とする。)

rc2のネイティブ(アンボックス)表現を実現する仕組みの実装ノート。将来のセッションが、設計を導き直したり、すでに見つけて直したバグをもう一度見つけ直したりせずに、全体の文脈を取り戻せるように書いてある。当初のStage 2〜3の実装に加え、その後のリファクタリングと修正も対象とする(`git log`を参照。`2026-08-12`付の「reduce unnecessary variable/statement generation」「ROp's operand-drop」「elide dup/drop for always-tagged PrimTypes」と、`2026-08-13`付の比較/分岐融合のコミットである)。本書の仕組みと相互に作用する、IRレベルのもう一方のパスについては`doc/reuse-analysis.md`を参照(どちらも同じ`natives`集合を参照する)。

## 問題

Idris2自身のコンパイル済みIR(`Lifted`)は、すべての値を一様に、ボックス化された`IDRIS2RC2_Value*`として表現する。そのままでは、`x * x + 1`のような算術の連鎖で、中間結果のたびに新しいヒープセルを確保し、参照カウントで管理することになる。RefCは実際にそうしている。rc2のネイティブ型推論は、*関数ローカル*な数値の中間値について、これを省く。そうした値は、1つの関数本体の中にとどまるかぎり、生のCスカラー(`int64_t`、`double`、...)としてスタック上に置かれ、ヒープ確保も参照カウントの操作も発生しない。

**意図的なスコープの境界**(`TODO.md`の「Scope」節を参照): 対象は、数値の`PrimFn`かリテラルから直接得られる、`RLet`束縛の中間値だけである。関数の*引数*と*戻り値*は、無条件にボックス化されたままになる。呼び出し規約自体は変えていない(ネイティブ/ボックス化の二重ABIはない。これは残された最大の改善手段であり、`TODO.md`の「Performance」節で別に管理している)。`Integer`(GMP)と`String`は、文脈にかかわらずネイティブ化の対象にならない。

## 決定を下す場所と保存する場所

再利用パス(フェーズ1+2のあとに走る、独立した木の書き換えパス)と違い、ネイティブかボックス化かは、`RC.idr`のフェーズ1(`normalize`/`bindCompound`)の最中に**インラインで**決まる。束縛される値に`Types.repOf`を呼び、その結果を`RLet`ノード自身の`Rep`フィールド(`RBoxed | RNative PrimType`、`RCExp.idr`)へ直接保存する。この決定のための独立した木全体の解析パスも、サイドテーブルもない。`Emit.idr`の`RepMap`は、各`RLet`を*出力する*ときに少しずつ埋められる。しかしこれは、後続の*使用*箇所(素の`RCLocal`のidしか持たず、決定を下したノードは持たない)が、すでに下された決定を引けるようにするためにすぎない。決定が下される場所は`RepMap`ではない。

### `Types.idr`の決定関数

- `nativeEligible : PrimType -> Bool`: 対象になる集合は`Int`、`Int8`/`16`/`32`/`64`、`Bits8`/`16`/`32`/`64`、`Double`、`Char`である。`Integer`/`String`を含まない点に注意する。
- `opResultRep : PrimFn arity -> Maybe PrimType`: ある`PrimFn`の結果がネイティブ化の対象になる場合の`Rep`。算術/ビット演算のすべてと、`Double*`の数学関数のすべてを網羅している。比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)は**意図的にここにない**(下の「比較は別の、より限定された仕組み」を参照)。`Cast i o`は、2つの型の両方を見る必要がある唯一のケースである。結果がネイティブになるのは、`i`と`o`の*両方*がネイティブ化の対象のときに限る(`nativeEligible i && ifNative o`)。ネイティブ化の対象でない変換元(GMPの`Integer`、`String`)からの変換は、変換先の型がネイティブ化の対象であっても、ボックス化された`idris2rc2_cast_*`の経路に残さなければならない。そもそも、読み出せる変換元のネイティブ表現が存在しないからである。
- `opArgTyFor : PrimType -> PrimFn arity -> PrimType`: 特定の演算のオペランドの型。その演算自身の(すでに決まっている)結果型`ty`を与えて求める。どの演算も、結果とすべてのオペランドで`ty`を共有する。例外は`Cast`で、その唯一の引数の型は結果型`o`ではなく、演算自身の変換元の型`i`である。この関数は`RC.idr`(どのボックス化オペランドが`alwaysUnboxed`かの判定)と`Emit.idr`(各オペランドの出力とアンボックス)で共有される。この対応関係の定義が、手作業で同期する2つではなく1つになるようにするためである。
- `litRep : Constant -> Maybe PrimType`: どの種類の数値リテラルの`Constant`がネイティブ化の対象かを返す。`RC.idr`の`bindOne`(オペランドにそもそも`RCConst`が必要かどうかの判定。下記参照)と`Emit.idr`の`repOfLocal`で共有される。
- `repOf : RCExp -> Maybe PrimType`: `RC.idr`が`RLet`/`bindCompound`のすべての箇所で呼ぶ、実際の入口である。`Native`を提案するのは`ROp`/`RPrimVal`だけで、素の変数の素通し(やそれ以外のもの)は`Boxed`のままになる。*合成された*`RLet`の連鎖を通り抜けて、その下にある本物の`ROp`/`RPrimVal`を見つける。フェーズ1自身のANF正規化は、オペランドが単なる変数でないたびに、合成された`RLet`を1つ導入する(たとえば`d * 2`のリテラル`2`)。**この通り抜けは、それ自体が実際のバグの修正だった**(下の「見つかったバグと修正」を参照)。これがないと、自分のオペランドの1つのために合成された`let`で包まれた演算が、ネイティブ化の対象と認識されなくなる。
- `alwaysUnboxed : PrimType -> Bool`: `nativeEligible`とは*別の*概念であり、取り違えやすい。rc2のランタイムは、`Int8`/`16`/`32`、`Bits8`/`16`/`32`、`Char`を、常にタグ付きポインタとして表現する(ペイロードをポインタのワード自体に詰める。`support/rc2/datatypes.h`を参照)。実際のヒープ確保は決して行わない。`Int`/`Int64`/`Bits64`(小さな整数のキャッシュの外では確保する)や`Double`(常に確保する)とは異なる。これは*ボックス化された*値(Cのレベルでは依然として`IDRIS2RC2_Value*`。たとえば通常の関数引数)についてのランタイム表現上の事実である。*ローカル*変数が上記のネイティブ扱いを受けたかどうかとは関係がない。このような値に対する`idris2rc2_dup`/`drop`/`free`は、どのみち無条件で何もしない。そのため、呼び出しを生成すること自体が無駄である。`RC.idr`の`alwaysUnboxedBoxedLocalsR`が参照する(下の「`natives`集合」を参照)。
- `cmpOpTy : CmpOp -> PrimType`(`RCExp.idr`): 比較/分岐融合(下記)と同時に追加された。`LT`/`GT`/`EQ`/`LTE`/`GTE`に共通するオペランド型である。この5つ自体には`opResultRep`のエントリがない。`CmpOp`は演算と、消去された`IsCmp`の証明を対にしたものなので、`RCmpCase`が保持できるのはこの5つのどれかに限られる。

### `RCLocal.RCConst`: リテラルは`RLet`を経由しない

ネイティブ化の対象になるリテラルのオペランド(`litRep`が対象とするもの)には、`RLet`+`RPrimVal`の組が一切作られない。`RC.idr`の`bindOne`がその場で`RCConst c`(`RCExp.idr`の`RCLocal`型)を直接作り、idの割り当ても合成束縛も行わない。`Emit.idr`は、読まれる場所ごとにこれをインラインのリテラル式として出力する(`repOfLocal`/`inlineExprFor`)。Cの宣言も、`RepMap`/`InlineMap`の帳簿も要らない。所有権を扱うあらゆる場所(`Owned`集合、`natives`集合、`RDup`/`RDrop`/`RFree`の対象)では、`RCConst`をネイティブなローカル変数と同じに扱わなければならない。つまり除外し、決して触らない(`RC.idr`の`splitBorrows`の最初の節)。

## `natives`集合: 所有権解析(フェーズ2)の一貫性の保ち方

フェーズ2(`annotate`)は、*すべての*ローカル変数の*すべての*使用について、それが参照カウントにそもそも関わるかどうかを知る必要がある。`annotateDef`が定義ごとに1度作る`natives : SortedSet RCLocal`の集合(`definitionNatives`)には、まったく別の2つの理由でローカル変数が入る。

1. **`nativeLocalsR`**: 本当に`RNative`の`Rep`を持つ、`RLet`束縛のローカル変数(フェーズ1自身の決定を、木から読み戻したもの)。参照カウントがまったくなく、ボックス化もされていない。
2. **`alwaysUnboxedBoxedLocalsR`**: ネイティブな演算自身のオペランド位置で、*型*が`Types.alwaysUnboxed`であるボックス化のローカル変数(典型的には関数引数)。これらはCのレベルでは参照カウントを*持つ*が、それに対する操作はどれも何もしないはずだったので、(1)とは別の理由で除外される。

`natives`を使うすべての箇所(`splitBorrows`、`boxedOperands`、`RV`のケース、`RLet`の`owned'`/`dropDeadLet`、`annotateConAlt`)は、この2つを同一に扱う。ローカル変数がどのように、何回使われても、dup/drop/freeは行わない。入口が2つあること、そしてすべての使用箇所が両者を同じに扱わなければならないことによって、always-unboxedの省略は新しい判定ロジックを足さずに入った。のちに、これを見落とした2つのラッパー生成経路があった(下の「見つかったバグと修正」の6を参照)。

## IRに保存するものと、出力時に導き直すもの

このコードベースには、繰り返し現れる設計上のパターンがある。**フェーズ2が決め、Emit.idrは低水準化だけを行う**というものである。フェーズ2の決定を`Emit.idr`に導き直させずに出力まで届けるため、2つのフィールドを用意している。

- `RLet.Rep`: フェーズ1自身の、ネイティブかボックス化かの決定(フェーズ2ではない。上を参照)。ただし「一度だけ決めてノードに保存する」という原則は同じである。
- `ROp.postDrop : List RCLocal`: 演算が読み終えたあとにdropしなければならない、*すべての*ボックス化オペランド。*出現*ごとに1エントリなので、`x + x`は`x`を2回並べる。フェーズ1は常にこれを`[]`として作る。フェーズ2の`annotate`が`boxedOperands natives (toList args)`で埋める。これは「ネイティブでも`RCConst`でもない」ものを単純に拾うフィルタである。演算がオペランドを読む前に*dup*が必要だったかどうかを決める`owned`/借用の帳簿(`splitBorrows`)からは独立している。演算が読むたびに、ボックス化されたオペランドの出現1つにつき、ちょうど1回のdropが必要になる。その出現が(所有された状態で)移動してきたものでも、借用のためにdupされたものでも同じである。dupがあるとすれば、それは読み出しに、消費するための自分の参照を与えるためだからである。

このフィールドは、以前は*存在しなかった*。`Emit.idr`が出力時に、`keepBoxedLocals`というヘルパーで「自分のオペランドのうちボックス化されているものはどれか」を独立に導き直していた。このヘルパーは、`emitRC`と`emitNativeValue`の`ROp`のケースが別々に呼んでいた。独立した2つの呼び出し箇所が原理的には食い違いうるため、ここは、`RCExp.idr`自身の「Emitは純粋に機械的である」という主張が実際には成り立たなかった唯一の箇所だった。この危険をなくし、あわせて後述のalways-unboxedの省略のために更新すべき真実の源を2つではなく1つにするため、フェーズ2が計算する単一のフィールドへ移した。

## 出力(`Emit.idr`)

- `nativeCType : PrimType -> String`: 生のCの型(`int64_t`、`uint8_t`、`double`、...)。
- `nativeMk : PrimType -> String -> String` / `nativeUnbox : PrimType -> String -> String`: ネイティブなC式を新しい`IDRIS2RC2_Value*`にボックス化する関数と、ボックス化された値を生のC式へアンボックスする関数(`idris2rc2_mkInt64(...)` / `idris2rc2_to_i64(...)`など)。値が2つの世界を行き来する境目(関数境界、コンストラクタのフィールド、caseの判別対象)で使われる。
- `rcVarToNativeC`/`rcVarToBoxedC`: `RCLocal`を、それぞれネイティブなC式、ボックス化されたC式として読む。どちらも`Rep`を見て振る舞いを変える。すでにネイティブなローカル変数はそのまま読み、ボックス化されたものはその場で`nativeUnbox`する。`RCConst`や`InlineMap`に入っているローカル変数は、リテラルや式のテキストをインライン展開し、そのための`var_N`を宣言することはない。これらは自分ではdup/dropを行わない。*使用*のために必要だった参照カウントの調整は、木のもっと前の段階で、包む`RDup`/`RDrop`/`RFree`ノードとして明示済みである(例外は`ROp`の`postDrop`で、これは自分の注釈を持つ)。
- `cOp`(結果がボックス化される演算。ボックス化版のランタイム関数を呼ぶ。たとえば`idris2rc2_add_Int64(x, y)`は新しい`IDRIS2RC2_Value*`を返す)と`nativeOpExpr`(結果がネイティブな演算。生のC式で、たとえば`(x + y)`は確保を一切伴わない): 同じ`PrimFn`の空間に対する2つの出力器であり、`Types.opResultRep`がこの演算の結果をここでネイティブと判定したかどうかで使い分ける。
- `emitNativeValue`: `emitRC`に対応する、ネイティブ型版である。`ROp`/`RPrimVal`を包む`RLet`/`RDup`/`RDrop`/`RFree`の連鎖をたどり、生のC式の文字列を作る。あわせて、保留中のボックス化オペランドのdropも返す。これは、その式を実際に使ったあとで*呼び出し側*が出力しなければならない。この関数自身が出力してはいけない理由は、下の「postDropの順序の退行」を参照。
- `InlineMap` / `tryInlineNativeOp`: ネイティブとボックス化という基本の区分の上に重ねた、さらなる最適化である。ボックス化オペランドを**1つも**持たず、**ちょうど1回**だけ使われるネイティブな演算は、`var_N`として宣言されることなく、式がその1つの使用箇所へ直接展開される。ボックス化オペランドがないことが、読み出しの先送りを常に安全にする(途中のどこかのdup/dropによって無効になるものがない)。使用がちょうど1回であることが、再計算を避ける。素のリテラルのオペランドはこの分類に最も多く当てはまり、同じ表の退化したケースとして扱われる。

## Boolを生成する比較の結果は`alwaysUnboxed`相当である

`RCmpCase`に融合されない比較(オペランドの型が`Integer`/`String`の場合や、融合できない形の場合)は、依然として`Boxed`の`Bool`を生成する。`support/rc2/idris2rc2_numeric.h`の`idris2rc2_{lt,gt,eq,lte,gte}_<T>`は、すべて`idris2rc2_mkBool(..)`で終わる。これは`Int8`のタグ付き即値である(`mkBool = mkInt8`)。この値に対する`dup`/`drop`/`free`は何もしない。それでも、結果に対する`case`は、以前はすべて`drop`で始まっていた。

そこで`alwaysUnboxedBoxedLocalsR`は、次の`Boxed`の`RLet`のローカル変数も`natives`に入れる。その`let`の値が、直接、`lazy = Nothing`の`ROp`であり、かつ演算が任意の`PrimType`の`LT`/`LTE`/`EQ`/`GTE`/`GT`のいずれかである場合である(`Types.boolResultOp`)。根拠にするのは**生成側だけ**、すなわち`let`の値である。消費側(`0 ->`/`1 ->`の`case`)から推論することは、意図的にしない。それ以外の方法で束縛されたBool(呼び出しの結果、`case`の値、エイリアス、パラメータ)は、従来どおり追跡の対象のままである。`natives`を使うすべての箇所は、このローカル変数を、上の節と同じように扱う。つまり、`dup`も`drop`も`postDrop`のエントリも生成しない。パラメータ(DualABIの`wrapperPostDrop`/`alwaysUnboxedDropVar`、ループパラメータ)には手を付けない。対象は`let`束縛のローカル変数だけである。これを切り替える`--directive`のスイッチはない。

`rcexpr-lint`のリーク検査にも、同じ規則がある(`Leak.idr`の`boundToComparison`)。`natives`を共有していないからである。

`Test13NativeArgChain`の`check.sh`は、比較に束縛されたローカル変数がdupもdropもされないことを検証する。idris2-lspの最終IR(`--directive dumprcexpr`)では、次のようになった。

| | 変更前 | 変更後 |
|---|---|---|
| `drop`の行数 | 81,879 | 81,185 (-694) |
| `dup`の行数 | 81,217 | 81,217 |
| IRの行数 | 689,992 | 689,298 |
| `0`/`1`の判別対象に対する`drop`で始まる`case`のアーム | 4,008 | 3,380 (-628) |

残る3,380件は、呼び出し、エイリアス、分岐から来るBoolである。これらを扱うには、生成元の演算だけでなく、生成元の型が必要になる。

### Stage 2: Boolを返す関数

残っているアーム先頭のdropの最大の原因は、呼び出しだった(呼び出しの結果は、当初の4,008件のうち1,319件)。末尾が`B8`リテラル、ネイティブな`Bits8`の値、またはそのような関数の呼び出しである関数は、現在、`ret= Native Bits8`のワーカーを持つ(`boolReturnPlan`、`rc2/doc/dual-abi.md`の「Bool return」。`--directive noboolret`で無効にできる)。そのため、その呼び出し元は結果をネイティブな`Bits8`として束縛し、それに対する`case`は`drop`を必要としない。idris2-lspでは、`0`/`1`の判別対象に対するアーム先頭のdropが3,381件から2,633件に、ネイティブな`Bits8`のワーカーが362個から594個になった。根拠は、今も生成側だけである。`Int`の`0`リテラルは`Bool`ではない。比較プリミティブは、末尾としては固有の規則を必要としない。フロントエンドがそれを`B8`リテラル上の`case`に変えるからである。

### 型付き定数のcase判別対象

altがすべて、`alwaysUnboxed`な型(`B8`、`Char`、`Int8`など。`Types.litRep`)の定数である`case`では、Idris2の型付けにより(ローカル変数の型は1つである)、判別対象はタグ付き即値を保持している。それは`Bool`、すべて引数なしの列挙型、`Bits8`のいずれかである。この値に対する`dup`/`drop`/`free`は何もしない。そこで`Types.typedConstScrutinees`が、該当する本物の`RCLoc`を集め、`RC.definitionNatives`がそれを`natives`に合流させる。これは、`alwaysUnboxed`な演算のオペランド(`alwaysUnboxedBoxedLocalsR`)の場合とまったく同じ扱いである。スイッチは`--directive noboolcase`である。

これは**Boolであることの判定ではない**。根拠が決めるのはアンボックスだけであり、しかも型付きである。根拠にするのは定数の種類(`B8 0`)であり、素の`0`/`1`ではない(`Int`や`Nat`のマッチは`I`/`BI`のaltを持つので、該当しない)。`Bits8`や列挙型の判別対象は2..255の値を取りうる。`1 -> A; _ -> B`というcaseは、意味を正確に保つ。ここでも`Emit`でも、ほかのどのパスでも、これを真偽値の判定や「0/1のもう一方」の分岐に書き換えることはない。0/1の形の二分岐への書き換えは`boolBranches`だけであり、これが発火するのは、融合された比較の結果に対してだけである。`boolProducer`、`boolReturnPlan`、`B8 0`/`B8 1`のリテラル検査は、いずれもこの集合を読まない。

このような定数のローカル変数をネイティブに読む呼び出しは、以前は、その変数を`RAppNameRep`の`postDrop`に加えていた。そのため`applyCallSiteRewrite`は、定義内のすべての`postDrop`からこれらのローカル変数を取り除く(`stripImmediatePostDrop`)。そうしないと、`annotate`にはそのdropと対になるdupがなくなる。

ダンプは、always-unboxedな型のaltの定数を`u: <c> ->`と表示する(`Pretty.immediateMark`)。`rcexpr-lint`は定数の型を見られないので、同じ集合を導き直す(`Leak.typedImmediateAlts`。フィクスチャは`tools/rcexpr-lint/tests/typedcase.rcexpr`)。したがって、`u:`のローカル変数は、`--directive noboolcase`のダンプでもリーク検査の対象から外れ、そこでは検査が弱くなる。`DualABI`は、自分の入力に対してこの集合を再計算する。後続のパスがこのような`case`を追加したり取り除いたりした場合は、`annotate`のものと食い違いうる。ただし、これは実行時には無害であり(即値だからである)、idris2-lspのIRはlintをクリーンに通る。

idris2-lspで、同じコンパイラを使い、`--directive noboolcase`を既定と比べて計測した。

| | `noboolcase` | 既定 |
|---|---|---|
| `drop`の行数 | 80,467 | 78,871 (-1,596) |
| `dup`の行数 | 79,112 | 79,113 |
| IRの行数 | 680,384 | 678,789 |
| alwaysUnboxedな定数の判別対象に対する`drop`で始まる`case`のアーム | 1,463 | 526 |

発生源ごとに見ると、1,453件(計測に使った、種類タグ付きのダンプにおける`B8`だけの件数。上の1,463は、`Char`などのalways-unboxedなaltの種類も数えている)の内訳は、コンストラクタのフィールドが508、`case`の値の`let`が253、`dup`のエイリアスが231、呼び出しの結果が204、その他が181、パラメータが6、ループパラメータが1だった。(`B8`のaltで判別されるパラメータは、`paramEligibility`によって、すでにネイティブな`Bits8`になっている。パラメータに対して全プログラム規模の生成側の不動点を求めても、増えるのは1%未満にとどまると見込まれるのは、このためである。)コンストラクタのフィールド(約500件)は、次の節で扱う。列挙した発生源の合計は1,453ではなく1,384なので、約70件は内訳が示されていない。

### always-unboxedなコンストラクタのフィールド(`--directive noboolfield`)

型付き定数の`case`が判別するコンストラクタのフィールドも、即値である。ところが、`annotate`より後の2つのパスが、`natives`を見ずに、参照カウント操作を付けていた。

- `Reuse.resolveReuse`は、altがdropしない分解済みフィールドのすべてを、判別対象をdropする前にdupする。また、すべてのフィールドを`reuseOffer`の`dupOnShared`/`dropOnUnique`に載せる。
- `ConAltNative.shadowOneField`は、昇格したフィールドの所有権を一から導き直す(`reannotateFieldOwnership`。末尾に`drop`が付く)。

この2つは、定義の中で`typedConstScrutinees`が見つけた集合(`RC2.immOf`)を受け取り、それらのフィールドを対象から外す。dropの前のdupも、`dupOnShared`/`dropOnUnique`のエントリも、導き直されたdropも生成しない。`--directive noboolfield`で無効にできる(根拠を借りている`noboolcase`のもとでも無効になる)。変わるのは、参照カウントの帳簿だけである。安全である理由は、次のとおりである。

- 根拠は上と同じ型付き定数であり、素の`0`/`1`ではない。`case`とそのデフォルト分岐には手を付けない(`Bits8`のフィールドは2..255の値を取りうる)。
- `Emit.emitConAltBody`は、altの入口で、各フィールドをセルからCのローカル変数へコピーする。親のdropが走るより前である。そのため、親が解放された後も、即値は有効なままである。即値には、自分自身の参照は要らない。
- セルが再利用される一意な親では、フィールドのスロットは上書きされる。古い即値にdropは要らない。共有された親では、セル自身のdropがそのフィールドについて解放するものはない。
- 別のコンストラクタに格納されたり、ボックス化のまま呼び出しに渡されたりしたフィールドも、同じタグ付きワードのまま渡される。`natives`に載っているローカル変数は、数えられることがない。

`rcexpr-lint`にも、対応する変更が必要だった。このことは、最初の、より広い試み(`ConAltNative`の後で、これらのローカル変数に対するすべての参照カウント操作を取り除く)が報告した異常の説明にもなっている。use-after-freeの検査は、caseのフィールドを、その判別対象を*借用している*ものとして扱う。そのため、`drop [parent]`の後でdupなしに読まれるフィールドが、問題として検出される。これはヒープ上のフィールドには正しく、即値には誤りである。`Lint.idr`は、`u:`のcaseのローカル変数すべてに、事実上無制限のカウントを与え(`seedImmediates`)、借用されたフィールドとして再束縛しない。そのため、このような読み出しは問題にならず、残ったdup/drop(`noboolfield`の形)がアンダーフローすることもない。`typedcase.rcexpr`には、親のdropの後でフィールドを読む形がある。同じファイルから`u:`の印を外すと、今でも問題として検出される。狭い版を1回実行したとき、`con`の引数の過剰消費も報告された。これはlintの問題ではなかった。1つの`reuseOffer`の`dupOnShared`が、誤ったローカルid(`v261316`ではなく`v271316`)を出力したのである。idris2-lspを連続して2回コンパイルしたときに発生し、その後の6回の同一の実行では発生していない(原因は不明。TODO.mdを参照)。

idris2-lspで、同じコンパイラを使い、`--directive noboolfield`を既定と比べて計測した。

| | `noboolfield` | 既定 |
|---|---|---|
| `dup`の行数 | 79,113 | 78,483 (-630) |
| `drop`の行数 | 78,871 | 71,191 (-7,680) |
| IRの行数 | 678,789 | 670,479 |
| alwaysUnboxedな定数の判別対象に対するアーム先頭のdrop | 526 | 120 |

(残った120件のうち、13件がフィールド、14件がパラメータである。残りは`let`束縛されたボックス化の呼び出し結果などである。) `Test13NativeArgChain`は、`1 -> ..; _ -> ..`を通した、値が2のフィールドと255のフィールドを扱う。また、親がdropされた後で読まれるフィールドと、`tcBump`も扱う。`tcBump`は、そのようなフィールドを持つコンストラクタを、共有された値と一意な値のそれぞれについて作り直す(再利用する)。`check.sh`は、スイッチを指定した場合と比べて、アーム先頭のdropと`dupOnShared`のエントリが少ないことを検証する。

## 比較は別の、より限定された仕組み(`RCmpCase`)

比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)は`opResultRep`に**ない**ことが目立つ。算術のようにネイティブな`RLet.Rep`を持つことはない。代わりに、比較が、Idris2自身のBoolの符号化(`False=0`/`True=1`)に対する二分岐の、唯一かつ直接の判別対象になっているとき、`RC.idr`の`normalize`がその形全体を専用の`RCmpCase` IRノードへ融合する(`tryFuseCompare`、`boolBranches`、`constantBoolValue`)。比較は生のCのブール式になって`if`に直接埋め込まれ、ネイティブであれ何であれ、ボックス化された値が実体化されることは一切ない。これは、このモジュールの上に重ねた(そして`nativeEligible`を再利用する)別個の最適化であり、`RLet.Rep`の仕組みの拡張ではない。設計の全体と、そのバグ(`annotate`の`RCmpCase`のケースにあった二重解放で、本書の内容とは無関係)については、`doc/`のコミット履歴と`BENCHMARKS.md`の「比較/分岐融合」節を参照。

### ボックス化されたオペランド(`Integer`、`String`)の比較

`Integer`と`String`は`nativeEligible`ではない。しかし`tryFuseCompareOp`は、これらも融合する(`Types.boxedCmpEligible`)。同じ`RCmpCase`で、オペランドが素のボックス化されたローカル変数になる。ネイティブの場合との違いは、次のとおりである。

- **条件。** `Emit.emitCmpCaseInto`は、(`ROp`と同じく)`boxOpArg`でオペランドを読む。`Emit.Util.boxedCmpExpr`は、`idris2rc2_<op>_<ty>_raw(a, b)`を出力する。これは`idris2rc2_numeric.h`にある`static inline int`のヘルパーである。`Integer`には`idris2rc2_integerCmp`を使うので、即値の高速な経路はインラインのままで、GMPの経路は呼び出しのままになる。`String`には`idris2rc2_strcmp3`と、長さ比較の後の`memcmp`を使うので、NUL文字で比較が終わることはない。`mkBool`の形である`idris2rc2_<op>_<ty>`は、現在は`_raw`のものを包むラッパーである。
- **所有権。**ネイティブの場合と変わらない。`annotate`の`RCmpCase`のケースは、ボックス化された各オペランドに`postDrop`のエントリを1つ与える(オペランドがまだ使われるなら、dupしたうえで)。`emitCmpCaseInto`は、条件を評価した直後、どちらの分岐よりも前に、それらをdropする。Boolのローカル変数がないので、`dup`/`drop`も、結果に対する`to_i64`もない。
- **shadowは作らない。**オペランドの型がネイティブではないので、`Loop`の`nativeArgTypes`/`nativeArgTypesFor`は、このような`RCmpCase`を無視する。`Integer`の比較でしか読まれないループパラメータは、ボックス化のままになる。

形の条件は、上のものと同じである(比較そのものが、二分岐の判別対象である)。それより前に比較へ`let`束縛された変数に対する`case`は、融合されない。

### ネストした比較のマージ(`Compiler.RC2.CmpMerge`)

`compare x y /= GT`は`x <= y`である。しかし、calleeを先に処理するインライナー(`doc/inlining.md`)が`compare`を展開すると、同じ分岐を2回持つ、ネストした2つの比較になる。

```
cmp <T  [x, y] then A  else  cmp ==T [x, y] then A' else B     -- A' equals A
==>
cmp <=T [x, y] then A  else  B
```

`Compiler.RC2.CmpMerge`は、dup/dropの注釈より前の`RCExp`に対して、これを書き換える。early inlineの再畳み込みの後に動くので、展開された箇所も見える。この時点では`postDrop`のフィールドはまだ`[]`である。`--directive nocmpmerge`で無効にできる。

- **組み合わせ。** `{<, ==}`は`<=`に、`{>, ==}`は`>=`になる。厳密な比較は外側でも内側でもよく、オペランドの順序はどちらでもよい(`a > b`は`b < a`として読む。`==`は対称である)。2つの比較は、同じオペランド型を持たなければならない。その型は、そもそも融合できるもの(`nativeEligible`または`Types.boxedCmpEligible`。つまり`Int`とほかの固定幅の型、`Char`、`Double`、`Integer`、`String`)である。マージされたノードは、厳密な比較のオペランドを引き継ぐ。
- **分岐が等しい場合。** 2つの`then`の分岐は、ソース位置の違いと、その内側で束縛されたローカル変数の名前の違い(`RLet`の変数とコンストラクタaltのフィールドは、順に対応付ける)を除いて、等しくなければならない。等価性が扱わないコンストラクタは、等しくないものとして比較される。その場合、マージの機会を逃すだけである。`Db`の定数は、表示した形で比較する。したがって、`==`が等しいとみなす`0.0`と`-0.0`は、区別されたままになる。
- **分岐が等しい比較。** (`compare x y /= LT`は、`cmp ==T [x, y] then T else T`を残す。)この比較は、その分岐だけを残して取り除く。
- **NaN。**どのマージも、`Double`のNaNに対するすべての結果を保つ。NaNでは`<`、`==`、`<=`がすべて偽になるので、どちらの形でもelseの分岐を取る。否定や分岐の入れ替えは、成り立たなくなるので、意図的に行わない。`cmp < then A else B`は、NaNに対しては`cmp >= then B else A`と等しくない。

これが発火する場所は限られる。`idris2-lsp`では、ほとんどどこにもない(TODO.mdを参照)。`Ord Int`/`Integer`の`compare`は呼び出しのままであり(書き換えた本体が`delegatingThreshold`を超える)、ほかの場所では`<=`がすでにプリミティブだからである。発火するには、`compare`の展開がインライン化される必要がある。これが起きるのは、`String`、`Char`、`Double`の呼び出し元が1つだけの`compare`(early inline)と、手書きの`if x < y then A else if x == y then A else B`である。計測では、手書きのマージ済みの形を2億回反復すると、`Int`と`Double`で、10.48秒ではなく9.86秒(約6%)かかった。`compare x y /= GT`を通した`String`の挿入ソートは、0.139秒ではなく0.134秒で、比較ごとに`strcmp`が1回減る。

## 見つかったバグと修正(時系列。コミット単位の詳細は`git log`と`BENCHMARKS.md`を参照)

1. **`Cast Integer Int`でのメモリ破壊。** `opResultRep (Cast i o)`は当初、`o`(変換先の型)だけを調べ、`i`(変換元の型)を調べていなかった。GMPの`Integer`(常にボックス化される、任意精度の型)からネイティブ化の対象の型への変換が、誤ってネイティブ化の対象と扱われ、ヒープのポインタを生の`int64_t`として解釈してしまった。`nativeEligible i`も要求することで修正した。
2. **合成されたletによる不透明化。** `d * 2`は、リテラル`2`を、本物の`ROp`を包む合成された`RLet`に束縛する(フェーズ1のANF正規化は、自明に見えない*すべての*オペランドを一様に束縛する)。`repOf`と`emitNativeValue`の初期版はこの包みを見通せず、式全体がネイティブ化の対象であることを見逃した。`repOf`(と、それに対応する出力のロジック)が合成された`RLet`の連鎖を通り抜けて、本物の`ROp`/`RPrimVal`を見つけるようにして修正した。
3. **ネイティブな結果を返す演算でのボックス化オペランドのリーク。** `annotate`の所有権解析は、ネイティブな結果を返す`ROp`のオペランドにも、ほかの値と同じ所有/借用の帳簿を適用し、最後の使用を「消費された」と扱う。ところが`Emit.idr`の`emitNativeValue`には(`emitRC`のボックス化された`ROp`のケースと違って)対応する後始末がまったくなかった。ネイティブへのアンボックス抽出でしか読まれないボックス化オペランドは、呼び出しのたびに参照を1つリークした。`Test112Numeric/NativeInts.idr`で見つかった。`ROp.postDrop`(上記)は、まさにこの誤りが二度と起きないようにするために存在する。`emitRC`と`emitNativeValue`が同一に低水準化する、フェーズ2が計算する単一のフィールドであり、独立に手書きされた2つの後始末の箇所ではない。
4. **postDropの順序の退行**(バグ3を直している*最中*、本来の修正を入れる前に見つかった)。最初の素朴な試みでは、不足していたdrop呼び出しを`emitRC`のボックス化された`ROp`のケースと同じ相対位置に追加した。しかし`emitNativeValue`が返すのは完全な文ではなく、*インライン式の文字列*である。その式を埋め込んだ文を実際に出力するのは呼び出し側である。戻った直後にdropすると、その式で値を実際に読む文より*前に*、(Cの文として)dropが実行されてしまう。これは本物のuse-after-freeである。見えるのは64ビット型(`Int64`/`Bits64`。実際にヒープを確保する)だけで、8/16/32ビット型は`alwaysUnboxed`のタグ付きポインタ表現を使い、dup/dropが何もしないため、これらの幅ではバグが完全に隠れる。修正は、式を読む文を実際に出力する側(呼び出し側)に`postDrop`のローカル変数のdropを担わせ、しかもその文を出力した*後*にだけ行うことである。式を作る関数自身の中では決して行わない。`emitNativeValue`自身のドキュメントコメントが「ここではなく呼び出し側で」と明記しているのはこのためで、一度起きたバグの正確な形を記録している。
5. **`keepBoxedLocals`のフィルタの反転**(`postDrop`フィールドの導入より前からあり、RDup/RFreeの作業と並行して発見された)。フィルタの条件が逆だった。本来は本当に`RNative`の`Rep`を持つものだけを除外するつもりだったのに、「`RepMap`に登録済み(つまりlet束縛されている)」ものを除外していた。そのため、let束縛された*ボックス化*のローカル変数もdropのリストから誤って除外され、リークしていた。`RepMap`に含まれるかどうかではなく、`Rep`の値そのもの(`RNative _`のみ)でフィルタするように修正した。
6. **`alwaysUnboxed`の省略を、その後に追加された2つのラッパー生成経路が見落としていた。**この省略は、本書を最初に書いた時点から`RC.idr`の`annotate`パスに組み込まれていた。上記の仕組みに欠陥があったわけではない。`Types.alwaysUnboxed`自体も、`annotate`からの参照(`alwaysUnboxedBoxedLocalsR`。上の「`natives`集合」を参照)も、最初から正しかった。ところが、その数日後に追加された二重ABI関連の2つのコード経路は、それぞれ独自に、常にボックス化されるラッパー関数を合成していながら、この省略を参照していなかった。

   (1) `Compiler.RC2.DualABI`の`synthesizeWorker`(Stage 3a。二重ABIの対象となる通常の関数が書き換えられて得る、常にボックス化されるラッパー)。その`wrapperPostDrop`は、ネイティブに昇格したすべてのパラメータを、`PrimType`に関係なく無条件にdropしていた。(2) `Compiler.RC2.Emit`の`emitGenericForeignWrapper`(通常の`%foreign`宣言のための、常にボックス化されるCのラッパースタブ)。その`removeVarsArgList`は、FFIの引数をすべて変数名だけでdropしており、dropするかどうかの判断の前に、引数自身の`CFType`が捨てられていた。

   どちらも正しさのバグではなかった。`alwaysUnboxed`の値に対する`idris2rc2_drop`は、構成上、ランタイムで何もしないことが保証されている(上の`alwaysUnboxed`の項目を参照)。そのため、出力されたCは誤ったものではなく、無駄なものだっただけである。ただし、この2つの経路に限っては、`alwaysUnboxed`が存在する意義そのものを損なっていた。

   修正は、どちらも`Types.alwaysUnboxed`で直接フィルタすることである。`DualABI.idr`の`wrapperPostDrop`は、自身の`eligible : List (Int, PrimType)`を`alwaysUnboxed`でフィルタし、dropのリストにはalways-unboxedでない位置だけを残す。`Emit.idr`には共有のヘルパー`alwaysUnboxedDropVar : (String, String, CFType) -> Maybe String`を追加した。これは`createFFIArgList`/`discardLastArgument`と同じ`where`ブロックにあり、`emitGenericForeignWrapper`と`emitFastPackFixedWrapper`の両方の`removeVarsArgList`が使う。後者は一貫性のためだけである。`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`の引数は常に`CFUser`なので、実際には`alwaysUnboxed`のケースに当たらない。このヘルパーは、`cfTypeNative vt`が`Just ty`で、かつ`alwaysUnboxed ty`が成り立つとき、`Nothing`(dropを省く)を返す。

   関連する3つ目の箇所である`Emit.idr`の`emitFFIWorker`(Stage 3cのネイティブABIのFFIワーカーで、常にボックス化されるラッパーではない)も調べたが、修正は不要だった。そのボックス化の位置は、構成上、`cfTypeNative`がすでに`Nothing`を返した(そもそもネイティブ化の対象でない)位置とちょうど一致する。一方`cfTypeNative`は、`alwaysUnboxed`の型に対して必ず`Just`を返す。したがって、そのような型がこのワーカー自身のボックス化位置のdropリストに現れることは、構造上ありえない。

## ファイル

- `rc2/src/Compiler/RC2/Types.idr`: 上で説明した、純粋な決定関数のすべて。
- `rc2/src/Compiler/RC2/RC.idr`: フェーズ1(`repOf`を呼ぶ`bindOne`/`bindCompound`)と、フェーズ2(`nativeLocalsR`、`alwaysUnboxedBoxedLocalsR`、`definitionNatives`、`splitBorrows`、`boxedOperands`)。比較融合の別経路である`tryFuseCompare`もここにある。
- `rc2/src/Compiler/RC2/RCExp.idr`: `Rep`、`RLet.rep`、`ROp.postDrop`、`RCLocal.RCConst`、`RCmpCase`。
- `rc2/src/Compiler/RC2/Emit.idr`: `nativeCType`/`nativeMk`/`nativeUnbox`、`rcVarToNativeC`/`rcVarToBoxedC`、`cOp`/`nativeOpExpr`/`nativeCmpExpr`、`emitNativeValue`、`InlineMap`/`tryInlineNativeOp`、`RepMap`。あわせて`alwaysUnboxedDropVar`(上のバグ6)もあり、`emitGenericForeignWrapper`/`emitFastPackFixedWrapper`の`removeVarsArgList`が参照する。
- `rc2/src/Compiler/RC2/DualABI.idr`: 本書のフェーズ1/2の仕組みの一部ではないが、`synthesizeWorker`の`wrapperPostDrop`が、`Types.alwaysUnboxed`の2つ目の、独立した利用者である(上のバグ6)。通常の関数に対する`annotate`の`alwaysUnboxedBoxedLocalsR`と同じやり方で、二重ABIのラッパーのdropリストをフィルタする。

## 検証方法

1. ビルドと回帰のベースライン: `CLAUDE.md`の「Build & test」節を参照する(`idris2 --build rc2.ipkg`のあと、`tests/refc-suite/run.sh`を実行し、19/19を期待する)。
2. `tests/Test112Numeric/NativeInts.idr`は、符号付き/符号なしのあらゆる幅の、8種類の固定幅整数型すべてを、同じ算術の連鎖に通す。出力は、境界値でのラップアラウンドを含めて、本物の`idris2 --cg refc`の出力とバイト単位で比較される。上のバグ3/4を見つけたのはこのテストであり、この領域に手を入れるときは最初にこれを再実行する。
3. `tests/BenchChain.idr`の`poly`関数は、仕組み全体がエンドツーエンドで機能することを示す標準的なデモである。生成されたCのヒープ確保/dup/dropの回数を、RefCのものと比べる(期待される正確な数値は`BENCHMARKS.md`の「算術チェイン」節を参照。確保3/dup 3/drop 4がrc2、8/6/16がRefCである。ここでの退行は、これらの数値がRefCの値へ戻っていくという形で現れるはずである)。
4. 生成された`.c`をgrepして、特定のPrimTypeのネイティブなCの型(たとえば`int8_t`)が、`IDRIS2RC2_Value*`/`idris2rc2_mk*`で包まれず、スタック上の素の変数として宣言されていることを確かめる。これによって、あるテストケースでアンボックスが実際に働いたことを確認できる。
5. 上のバグ6(`alwaysUnboxed`を見落とした、二重ABIのラッパーの2つの経路)には、独立した回帰の確認がある。どちらの経路も、上の`Test112Numeric/NativeInts.idr`が検証するために書かれた`RC.idr`の`annotate`パスからは到達できないためである。`tests/build/Test112Numeric_rc2.c`の`Main_chainInt8`/`chainInt16`/`chainInt32`(とBits8/16/32の対応するもの)を手作業で確認し、二重ABIのラッパーが引数に対して`idris2rc2_drop`をまったく呼ばなくなったことを確かめる。一方`Main_chainInt64`(ネイティブ化の対象だが`alwaysUnboxed`ではない。小さな整数のキャッシュの外では本物のヒープ確保になる)は、2つの引数を従来どおり正しくdropしている。同様に、`tests/build/Test27FFIDualABI_rc2.c`の`Main_prim__bumpChar`(`CFChar`/`Char`の`%foreign`ラッパー)は引数をdropしなくなり、`Main_prim__mixed`(`Int`+`String`。どちらも`alwaysUnboxed`でない)と`Main_prim__noop`は従来どおり正しくdropする。`verify.sh --regen-expected`の全件(85/85)と`refc-suite/run.sh`(19/19)がどちらも通っており、これが動作の変更を伴わない、純粋に生成コードの無駄の修正であることと整合する。
