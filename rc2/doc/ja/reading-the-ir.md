# rc2のIRを読む: `--directive dumprcexpr`のダンプと`RCExp`の構文

(原文: `doc/reading-the-ir.md`。内容が乖離した場合は原文を正とする。)

rc2独自の参照カウント付きIR(`Compiler.RC2.RCExp`)をダンプして読むための実用リファレンスである。
このIRは木構造で、`Compiler.RC2.Emit`がそれをそのままCに変換する。
生成されたCを読んだり、元のIdrisソースから推測したりせずに、「rc2はここで実際に何を決めたのか」を知りたいときに使う。
`doc/reuse-analysis.md`と`doc/native-type-inference.md`は、この文書と対になる。
あちらは、個々のパスが*なぜ*その判断をするのかを説明する。
この文書が扱うのは、すべてのパスを通ったあとの*結果の読み方*と、それを表示するツールである。

## 1. IRをダンプする

```sh
cd rc2 && source ../env.sh
nix-shell -p gcc gmp pkg-config --run \
  './build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr YourFile.idr -o out'
```

これで、生成される`out.c`の隣に`out.rcexpr`が書き出される。
場所は、`-o`が解決するディレクトリである。
`idris2-rc2`を実行したディレクトリの下の`build/exec/`で、`.c`や実行ファイルと同じ場所になる。
`--directive`は、上流Idris2自身が持つ、実行ごとに文字列を渡す汎用の仕組みである(Chez/ESのディレクティブと同じ仕組み)。
この機能のためにidris2-srcを変更する必要はなかった。
`Compiler.RC2.RC2`の`compileExpr`を参照する。

`idris2-rc2`の他のフラグ(`-p`、`--cg rc2`自体など)とは自由に組み合わせられる。
ダンプを出力しても、コンパイルされる内容やプログラムの挙動は変わらない。
副作用として、`prettyProgram defs`の結果をファイルに書くだけである。
この`defs`は、`generateCSourceFile`がこれから使うものとまったく同じ値である。

**パイプラインのどの時点の状態か。**
ダンプは、無効化されていない`toRCDefs`の全ステージが実行された*あと*に出力される。
つまり、`generateCSourceFile`がこれから使う`defs`そのものである。

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.InlineCExp      (whole-program inlining, before lambda lifting)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (constructor-reuse-in-place)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue)
  -> Compiler.RC2.Sink            (branch-local sinking, see doc/branch-sinking.md)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> [ .rcexpr dumped here ]
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

したがって、ダンプで見えるものは`Emit.idr`が受け取るものと*完全に同じ*である。
所有権の判断、再利用の申し出、ループへの変換、dual-ABIのワーカー/ラッパーへの書き換えが、すべて反映された状態で見える。
それより前のステージのダンプを出すフックは、現在ない。
たとえばPhase 1の直後、所有権が決まる前の状態が必要なら、見たい位置に`compileExpr`と同じ要領で`writeFile`の呼び出しを足せばよい。

**1つのファイルにプログラム全体が入る。**
ダンプには、`Compiler.RC2.RC2.toRCDefs`が出力したトップレベルの名前ごとに、`def`ブロックが1つ含まれる。
自分のモジュールの定義だけでなく、推移的に到達可能な`Prelude`/ライブラリの関数もすべて含まれる(`Prelude.EqOrd.==`、`Prelude.Show.show`など)。
`Int`の`==`インスタンス自体がどうコンパイルされるかを見たいときなどには、むしろ都合がよい。
ただしファイルが大きくなりうるので、まず`grep -n "^def "`で、目的の定義を探すとよい。

**注意点。**
ダンプは、デバッグのためだけのものである。
コンパイラ自身が読み戻すことはない(`.ttc`とは違う)。
rc2のバージョン間で形式が変わらない保証もない。
書式は網羅性より読みやすさを優先している(`Compiler.RC2.Pretty`のモジュールノートを参照)。
ソースの位置情報(span)は完全に落とされ、各コンストラクタには、実際のIdrisのコンストラクタ名の代わりに短いキーワードが付く。
この対応が、下の第3節の主題である。
`.rcexpr`ファイルは(生成された`.c`と同じディレクトリに置かれる)ビルド成果物であり、コミットしない。
必要になるたびに再生成する。

## 2. ダンプの構造

定義ごとに1つのブロックがあり、並びは`toRCDefs`自身の順序である。

```
def <Name>  (<kind> ...)
  <body, indented>

def <Name>  (<kind> ...)
  ...
```

`<kind>`は4種類あり、`RCDef`のコンストラクタに1つずつ対応する。

| ヘッダ | `RCDef` | 意味 |
|---|---|---|
| `(fun args=[v0, v1])` | `MkRCFun` | 通常の関数。本体が1段インデントして続く。 |
| `(con tag=Just 1 arity=2 newtype=Nothing)` | `MkRCCon` | データコンストラクタ自身のメタデータ(本体はない。コンストラクタは実行されず、構築やマッチをする呼び出し側のために記述されるだけである)。`tag=Nothing`は、タグなし、または単一コンストラクタの型を表す。`newtype=Just k`は、フィールド`k`が実行時の表現であり、コンストラクタ自体は消去されることを表す。 |
| `(foreign ["scheme:...", "C:foo,libfoo"] [CFInt, CFString] -> CFIORes CFUnit)` | `MkRCForeign` | FFI宣言。順に試される呼び出し規約の文字列、引数の`CFType`、戻り値の`CFType`が並ぶ。 |
| `(error)` | `MkRCError` | Idris2が実行時まで先送りする形でコンパイルに失敗した定義(まれ)。本体はクラッシュを起こす式である。 |

読み進める本体があるのは`(fun ...)`/`(error)`だけである。
この文書の以降の部分は、その本体の読み方を扱う。

**名前。**
ダンプに現れるすべての名前は、`dumpName`(`RCExp.idr`)を通る。
対象は、`def`のヘッダ、`call`/`callRep`/`partial`/`con`/`retpack`/`memoize`/`delay`の対象、case alt自身のコンストラクタ名、`#Name@tag`/`#Name/n~closure`の定数値である。
`dumpName`は、上流自身の`Show Name`(`idris2-src/src/Core/Name.idr`)に2つの調整を加えたものである。
1つ目は、`DN`(表示名。たとえばインターフェース実装のメソッド)の扱いである。
`DN`は、自身の短い表示文字列ではなく、それが*表している*名前を表示する。
これは、実際のCシンボルのために`Compiler.RC2.Emit.Util`の`cName`が使う名前と同じである。
たとえば`Prelude.Show.(show_Show_(List $a))`と表示される。
すべての`Show`実装で共通の、素の`Prelude.Show.show`にはならない。
2つ目は、`CaseBlock`/`WithBlock`の名前が、自身の添字を含むことである(`case block in f:3`。`f`の中のすべてのcaseブロックが、素の`case block in f`で重複することはない)。
このように、すべての定義がダンプ中で異なる名前を持つ。
そのため、`def <Name>`のヘッダや、それを指す`call`/`callRep`/`partial`の参照は、定義の数を数えたり、差分を取ったりするときのキーとして使える。

## 3. 値(`RCLocal`)

値が*読まれる*場所(オペランド、引数、scrutinee)は、すべて次の4つの形のどれかで表示される。
これは`RCExp.idr`の`Show RCLocal`であり、ダンプのいたるところに現れるので、覚えておく価値がある。

| 構文 | コンストラクタ | 意味 |
|---|---|---|
| `v0`、`v1`、`v42`、... | `RCLoc n` | 通常のローカル変数。関数のパラメータ、または`let`/パターンマッチ/ループパラメータで束縛されたもので、コンパイラが割り当てた整数で識別される。**IDは、パスをまたいで、また定義自身の引数と本体のあいだでも、安定していない。**ループのネイティブshadowは、元のパラメータ自身のIDとは別の*新しい* IDを受け取る(第8節を参照)。具体的な数字から読み取れるのは、「ここでは同じ番号は同じ値」ということだけである。 |
| `[__]` | `RCNull` | Cのリテラルの`NULL`。出どころは3つある。1つ目は消去されたnullaryコンストラクタの値(`Nil`/`Nothing`/`Z`/`MkUnit`。ヒープ割り当てがまったく不要で、NULLか非NULLかでマッチする)。2つ目はIOプリミティブの呼び出しに通される`%World`トークン(`extprim ... [[__], ...]`)。3つ目は`Compiler.RC2.MutualLoop`が、アリティの小さいグループメンバーの未使用の末尾スロットを埋めるために入れるパディングである。 |
| `#0`、`#"hello"`、`#'x'`、... | `RConst c` | ネイティブにできる、または安価なリテラルを、そのままインライン化したもの。`var_N`もlet束縛もdup/dropもない。どの定数が該当するかは、`doc/native-type-inference.md`の「`RCLocal.RCConst`」の節を参照する。 |
| `#Main.NoShape@1`、`#Prelude.Show.Open@0`、... | `RCEmptyCon n ci tag` | 上の4つの`RCNull`以外の、引数なしの*タグ付き*データコンストラクタ(たとえば、複数コンストラクタのenumに対する`f Red`)。`Name@tag`の形で、タグ付きポインタの定数としてインライン化され、割り当てはない。 |

## 4. 表現(`Rep`)

すべての`let`束縛と、すべての`loop`自身のパラメータリストに表示される。

| 構文 | 意味 |
|---|---|
| `Boxed` | 通常の、ヒープに割り当てられたか、タグ付きポインタの`IDRIS2RC2_Value*`。通常どおり参照カウントされる。 |
| `Native <PrimType>` | スタック上にある生のCスカラー(`int64_t`、`double`、`uint8_t`、...)。このローカル変数には、ヒープ割り当ても参照カウントも一切ない。`<PrimType>`はIdris2自身の型(`IntType`、`Int64Type`、`Bits8Type`、`DoubleType`、`CharType`、...)である。 |
| `InlineNative <PrimType>` | `Native`と同様だが、さらにCの変数がまったく宣言されない。計算式が、唯一の使用箇所にそのまま埋め込まれる。Phase 2が、通常の`Native`をここまで昇格させるのは、そのローカル変数がBoxedなオペランドを1つも持たず、使用箇所がちょうど1つであると分かったときである。Nativeで束縛されている*値*は見えるが、それに対する`let vN`の行はどこにもない(宣言されないからである)。 |

## 5. 式の構文の完全なリファレンス

`RCExp`のすべてのコンストラクタを、`Compiler.RC2.Pretty`が表示する簡潔なキーワードで示す。
`~<reason>`は、「このIdrisの`LazyReason`に従ったlazy」を表す任意の接頭辞である(`~Lazy`、`~Inf`、`~Unknown`)。
`RAppName`/`RApp`/`ROp`/`RExtPrim`自身の`lazy`フィールドが持つ。
`RC.idr`では、この4つを構築するすべての箇所で、このフィールドに`Nothing`を設定している。
後続のパスも、ここに入れる`LazyReason`を自分で作ることはない。
そのため、この接頭辞は実際にはダンプに現れない。
下の`delay`/`force`は、これとは別のフィールドで、常に値が入っている(`RDelay`/`RForce`自身の`lr`)。
そのため`LazyReason`が無条件に表示され、接頭辞の`~`は付かず、素の`Lazy`/`Inf`/`Unknown`になる。

| 構文 | `RCExp` | 意味 |
|---|---|---|
| `v0`(キーワードなし) | `RV` | この式の値は、ローカル変数`v0`そのもの(そのまま読まれる)。分岐自身の末尾の値(たとえば第8節の`sumTo`の基底ケース)として現れる頻度は、インラインの場合と同じくらい高い。 |
| `~r call Name [v0, v1]` | `RAppName` | `Name`をこれらの引数で呼ぶ。`~`なしで末尾位置にあるものは、`Compiler.RC2.Emit`のクロージャ構築ロジックが横取りする。それ以外の位置では、通常の(トランポリンされうる)呼び出しである。 |
| `partial Name missing=1 [v0]` | `RUnderApp` | 部分適用。これらの引数を渡した`Name`のクロージャを構築する。実際に実行できるようになるまで、あと`missing`個の引数が必要である。 |
| `~r apply v0 v1` | `RApp` | *構築済みの*クロージャ`v0`に、もう1つの引数`v1`を適用する(トップレベル関数を名前で直接指す`call`とは異なる)。 |
| `let v0 : Boxed =`<br>`  <value>`<br>`<body>` | `RLet` | `v0`を(表示された`Rep`で)`<value>`の結果に束縛し、`<body>`に続ける。最もよく現れるラッパーで、中間計算のほとんどすべてがこれを通る。 |
| `con Name ConInfo tag=Just 1 [v0, v1]` | `RCon` | これらのフィールドを持つ`Name`の値を構築する。`ConInfo`は、ソースレベルでどの種類のコンストラクタかを示す、Idris2自身の短いタグである(リスト型なら`[cons]`/`[nil]`、通常のコンストラクタなら`[data]`、そのほか`[record]`、`Nat`型なら`[zero]`/`[succ]`、`[enum N]`、`[unit]`、`[just]`/`[nothing]`など)。タグなし、または単一形状の型では`tag=Nothing`になる。末尾に`reuse=v2`が付いていれば、この構築は`v2`自身のストレージをその場で再利用してよい。第9節の再利用の例を参照する。 |
| `op PrimFn [v0, v1] postDrop=[v0]` | `ROp` | プリミティブ演算(`+Int`、`-Integer`、`cast-Integer-Int`、`==Char`など)。`postDrop=[...]`がある場合は、この演算がオペランドを読み終えたあとにdropが必要な*Boxed*オペランドをすべて列挙する。演算自身の読み取りを包む通常の`drop`を置ける文の位置がないので、代わりにこのフィールドが担う(`doc/native-type-inference.md`を参照)。この行が生のC式として出力されるか、Boxedなランタイム呼び出しとして出力されるかは、この行自身からは分からない。それは、*外側の* `let`自身の`Rep`で決まる。 |
| `extprim Name [[__], v0, v1]` | `RExtPrim` | rc2自身のランタイムプリミティブのグルーコードへの呼び出し(`IORef`、配列、FFIヘルパーのラッパー、`%World`を通すIOプリミティブ)。最初の引数は、`%World`トークンの`[__]`であることが非常に多い。 |
| `cmp PrimFn [v0, v1] postDrop=[...]`<br>`then`<br>`  <T>`<br>`else`<br>`  <F>` | `RCmpCase` | ネイティブな比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)を、2方向の分岐に*直接*融合したもの。Booleanの結果は、ネイティブな値としてさえ、値として具体化されない。生成されるのは、比較が、Idris2自身の`Bool`(`False=0`/`True=1`)の表現に対する2方向マッチの、唯一かつ直接のscrutineeである場合に限られる。第9節の具体例を参照する。 |
| `case v0 of`<br>`  Name ConInfo tag=Just 1 args=[v1, v2] ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConCase` | scrutinee `v0`のコンストラクタタグで分岐する。`args=[...]`は、このaltが`v0`自身のストレージから*直接*分解して取り出すフィールドである(ポインタのエイリアスであり、独立して参照カウントされるわけではない。`v0`が死ぬ可能性があるとき、これらが先に`dup`される様子は第9節を参照する)。`_ ->`は任意のデフォルト分岐で、それがなくても網羅的な場合はまったく現れない。 |
| `case v0 of`<br>`  0 ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConstCase` | scrutinee `v0`の*値*を、リテラル定数と照合して分岐する(整数のswitch、または`String`/`Double`の等価比較の連鎖)。コンストラクタタグでは分岐しない。 |
| `0`、`"hi"`、`'x'`(キーワードなし) | `RPrimVal` | リテラルの値そのもの。`#c`/`RCConst`が、letも割り当てもない*オペランド*の参照であるのとは違う。`RPrimVal`は、リテラルがBoxedな独自の実体を必要とする場合に(たとえば、ファイルスコープの定数へステージングされる場合)、合成された`let`が束縛するものである。 |
| `erased` | `RErased` | Idris2自身の多重度解析で、決して検査されないと証明された値。計算するものも、表現するものもない。 |
| `crash "msg"` | `RCrash` | 到達不能な経路(たとえば、Idris2が別の方法で網羅的だと証明した`case`)、または明示的な実行時パニック。`abort()`系の呼び出しに変換される。 |
| `dup v0`<br>`<body>` | `RDup` | `v0`の参照カウントを増やして(「参照を1つ追加」)、続ける。借用された使用が変換されるとこの形になる。 |
| `drop [v0, v1]`<br>`<body>` | `RDrop` | 列挙された各ローカル変数の参照カウントを減らし(0になれば再帰的に解放する)、続ける。所有権のクリーンアップとして最もよく現れる形である。`Compiler.RC2.RC`の`annotate`は、分岐自身の入口に、これを多くても1つだけ付ける。 |
| `free v0`<br>`<body>` | `RFree` | `v0`を、*無条件で*、チェックなしにただちに解放する。参照カウントの確認は一切ない。挿入されるのは、`annotate`が束縛自身の形だけから、`v0`が共有される機会のなかった新品のヒープ割り当てだと証明できる場合に限られる(`drop`が通常行う分岐とメモリ読み出しを省ける)。実際にはまれで、生成されたCのほとんどには現れない。フロントエンドの多重度に基づく消去が、これが発動する唯一の種類の束縛を、`RC.idr`が見る前にすでに取り除くからである(RefCで発動しないのも同じ理由による)。したがって、`grep idris2rc2_free`の結果が空なのは想定どおりである。 |
| `releaseReuse v0`<br>`<body>` | `RReleaseReuse` | 再利用の予約(次の行を参照)のうち、この実行経路では*消費されなかった*ものを解放する。 |
| `reuseOffer v0 dupOnShared=[v1, v2]`<br>`<body>` | `RReuseOffer` | 実行時の一意性チェック。`v0`が唯一の参照であれば、そのストレージが、同じ木の後ろにある`con ... reuse=v0`のために予約される。そうでなければ、`dupOnShared`のすべてのフィールドが追加の参照を得て(`v0`自身の通常の再帰的なdropのあとも生き残るため)、`v0`は通常どおりdropされる。第9節を参照する。 |
| `loop ["v4:Native Int", "v5:Native Int"] initial=[v0, v1]`<br>`<body>` | `RLoop` | 自己末尾再帰、または(`MutualLoop`でマージされたあとの)相互末尾再帰のループ全体。各ループパラメータ自身のIDと`Rep`が並ぶ。`initial`は、それぞれの開始値を同じ順序で与える(*外側の*スコープで、ループが最初に走る前に1回だけ評価される)。第8節を参照する。 |
| `continue loop [v2, v3]` | `RLoopContinue` | 最も内側の`loop`の先頭に戻り、これらを各パラメータの新しい値として与える。位置による対応で、その`loop`自身のパラメータリストと同じ順序である。単純なCの`goto`に変換される。 |
| `delay Lazy thunkName [v0, v1]` | `RDelay` | `thunkName`自身のクロージャを包むlazyセルを構築し、これらのキャプチャで飽和させる(キャプチャは消費される)。`Lazy`、`Inf`、`Unknown`はIdris2自身の`LazyReason`である(`show`したもので、`~`は付かない)。セルを最初に`force`したときに結果を評価して保存し、以後の`force`は保存された値をそのまま返す。`doc/lazy-memoization.md`を参照する。 |
| `force Lazy v0 postDrop=[v1]` | `RForce` | `v0`を(借用で)読む。lazyセルなら、評価済みの場合は保存された値を返す。未評価の場合は、セル自身のthunkを実行して値をキャッシュする。セルでなければ、`v0`をそのまま返す(セルを必要としなかった`Delay`。`doc/lazy-memoization.md`の「`Delay`」を参照する)。`postDrop`は`op`と同じである。 |

Altの構文は次のとおりである。`case`の中で使い、altごとに1行と、インデントされた本体が続く。

| 構文 | 意味 |
|---|---|
| `Name ConInfo tag=Just 1 args=[v1, v2] ->` | `RConAlt`。`RConCase`のscrutineeをこのコンストラクタと照合し、そのフィールドを、列挙された新しいIDに束縛する。 |
| `<constant> ->` | `RConstAlt`。`RConstCase`のscrutineeをこのリテラル値と照合する。 |
| `_ ->` | どちらのcaseでも使える、任意のデフォルト/フォールスルー分岐(これ自体は「alt」ではないので、インデントが1段深くなる)。 |

## 6. 所有権を一目で読む

木の他の場所でのlocalの*使用*は、すべて注釈のない素の`vN`/`[__]`/`#c`である。
参照カウントの増減は、暗黙には行われない。
必ず直前の独立した行(`dup`/`drop`/`free`)に現れる。
演算自身のオペランドに限っては、`postDrop=[...]`フィールドに現れる(演算は、オペランドを読んで結果を出す処理を一息で行うので、読み取りを包む`drop`を置ける文の位置がない)。
あるローカル変数`vN`が正しく扱われているかを監査するには、次の手順をとる。

1. 束縛されている場所を見つける(`let vN : ...`の行、または`fun args=[...]`/`RConAlt args=[...]`/`loop [...]`のリストへの登場)。
2. そこから到達できるすべての経路を前向きにたどり、素の使用、`dup vN`、`drop [..., vN, ...]`/`free vN`(`postDrop`の中も含む)をすべて記録する。
3. 所有された値は、どの経路でも、*ちょうど* 1つの正味の「最終処分」にたどり着くはずである。
   呼び出しやreturnで消費される(所有権が移るので、dropは不要)か、ちょうど1回drop/freeされる。
   唯一のdropのあとで使用がある経路や、間に再取得(`dup`)がないまま2回dropがある経路は、本物のバグである。
   `doc/native-type-inference.md`の「Bugs found」の節に記録されている、複数のリークやuse-after-freeを見つけたのは、まさにこの手作業の手法である。

再利用のプロトコル(`reuseOffer`/`con ... reuse=sc`/`releaseReuse`)は、3者間のハンドシェイクである。
単独でgrepして追えるような単純な線形の構造ではない。
下の第9節で、実際の例を最初から最後まで追う。

## 7. 自己末尾呼び出しがループになったかどうかを読む

本体が`loop [...] initial=[...]`で始まる定義では、少なくとも1つの自己末尾呼び出し(マージ後は、メンバーをまたぐ相互末尾呼び出し)が`goto`に変換されている。
その中にある`continue loop [...]`は、どれも変換された呼び出し箇所である。
末尾位置に通常の`call SameName [...]`がまだ残っている定義は、変換されていない。
相互再帰の場合は、自分自身が属していない`{rc2_mutualLoop:N}`のマージ済み関数を、通常のクロージャ/`call`の経路で呼んでいるものも、変換されていない。
こうした定義は、汎用の「クロージャを構築してトランポリンする」経路を通る。
`Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`を変更する前後で、「この定義の本体が`loop`で始まるか」を比べるのが、ある再帰関数がこの最適化の対象になっているかどうかを確かめる最も速い方法である。
生成されたCを見る前に、これで判断できる。

## 8. ネイティブshadow化されたループパラメータを読む

`loop`自身のパラメータリストには、各パラメータの`Rep`が直接表示される。
`"v0:Boxed"`は、外側の関数自身の呼び出し規約どおり、Boxedのままである。
`"v4:Native Int"`は、このループパラメータが新しいネイティブshadowに昇格されたことを意味する。
ループへの入口で、`initial`の対応する(まだBoxedの)値から1回だけアンボックスされる。
ループの*全期間*を通して、生のスカラーとして使われる。
再びBoxedになるのは、ループ内にBoxedを要求する使用がある場合だけである(コンストラクタのフィールド、ネイティブ非対応の関数への呼び出し、ループ自身の最終的なBoxedの結果)。
ここで大事なのは、シャドウ自身のIDが元のパラメータのIDでは**ない**ことである。
`initial`には、*元の*(常にBoxedの)引数のIDが引き続き並ぶ。
`loop`自身のパラメータリストには、*新しい*シャドウのIDが、その隣に位置で対応して並ぶ。

具体例として、`BenchLoop.idr`の`sumTo acc n = sumTo (acc + n) (n - 1)`を見る。

```
def Main.sumTo  (fun args=[v0, v1])
  loop ["v4:Native Int", "v5:Native Int"] initial=[v0, v1]
  case v5 of
    0 ->
      v4
    _ ->
      let v2 : Native Int =
        op +Int [v4, v5]
      let v3 : Native Int =
        op -Int [v5, #1]
      continue loop [v2, v3]
```

この読み方は次のとおりである。
関数自身のトップレベルの引数は`v0`(`acc`)と`v1`(`n`)である(外部の呼び出し規約どおり、常にBoxedである。`TODO.md`の「Dual calling convention」のギャップを参照する)。
ループは、これらを新しいネイティブshadow `v4`/`v5`で包み、入口で`v0`/`v1`から1回だけアンボックスする。
このアンボックスは、上のスニペットには表示されない。
通常の関数入口の処理にすぎず、`loop`の行には現れず、Emitの時点でしか見えないからである。
ループ本体内の参照は、すべて`v4`/`v5`を直接読み書きし、`v0`/`v1`を二度と使わない。
終了判定(`case v5 of 0 -> ...`)も算術(`op +Int [v4, v5]`、`op -Int [v5, #1]`)も、単純なネイティブ演算であり、Boxedの中間値はどこにもない。
`continue loop [v2, v3]`は、次の反復の値を位置で与える(`v2`が`v4`のスロットへ、`v3`が`v5`のスロットへ入る)。
基底ケースの`0 -> v4`は、シャドウをそのまま返す(関数自身の戻り値の型がBoxedなので、出口で、Emitの時点でボックス化される)。
ループ本体には、`dup`/`drop`/`free`がまったく現れない。
ネイティブの値には、これらが一切不要だからである。
生成されたCとタイミングの比較は、`rc2/BENCHMARKS.md`の2026-08-14のエントリにある。
この仕組みが*届かない*現実のパターン(ループで持ち回る値が、フィールド1つのコンストラクタに包まれている場合)は、`TODO.md`の「Native-shadow eligibility stops at bare top-level scalars」に書かれている。

## 8.5. 省かれた(ループ不変の)パラメータを読む

`loop`自身のパラメータリストには、外側の関数のトップレベルの引数1つにつき1エントリが必ずあるとは限らない。
`Compiler.RC2.Loop`の`applyLoop`は、各パラメータについて、本体のすべての`continue loop`がそれを完全に変更せずに渡しているかどうかを調べる(まったく同じローカル変数であることが条件で、等しく見える再計算では足りない)。
そうしたパラメータは、どの反復でも再代入されないことが証明される。
そのため、`goto`をまたいで無駄に持ち回すのをやめ、`loop`自身のパラメータリストと`initial`から完全に取り除かれる。

そのパラメータがその後どうなるかは、ネイティブshadowの対象だったかどうかで決まる。

- **Boxedのまま残った場合**: ほかには何も変わらない。元のIDは、外側の関数のトップレベルの引数のままであり、このパスが走る前と同じように、ループ本体のどこからでも直接読める。
- **ネイティブshadowの対象だった場合**: `loop`の*すぐ外側*に、1回だけの`let`+`drop`の組としてホイスティングされる。
  これは、下の第9節の`Compiler.RC2.ConAltNative`の例が、分解したフィールドのネイティブな読み取りをキャッシュするために使うのと、まったく同じ記法である。
  `Compiler.RC2.Loop`自身の`applyLoop`はこれをそのまま再利用し、1つのaltの本体ではなく、ループ全体を包む。

具体例として、`Test110Loop/LoopInvariantParam.idr`の`sumWithTag tag limit acc n = if n >= limit then acc + cast (length tag)else sumWithTag tag limit (acc + n) (n + 1)`を見る。
`tag : String`と`limit : Int`は、どちらも再帰呼び出しのたびにまったく変更されずに渡される。
実際に変化するのは`acc`/`n`だけである。

```
def {idris2rc2_worker_Main_sumWithTag:0}  (fun args=["v0:Boxed", "v1:Boxed", "v2:Boxed", "v3:Boxed"] ret=Native Int)
  let v12 : Native Int =
    v1
  drop [v1]
  loop ["v13:Native Int", "v14:Native Int"] initial=[v2, v3] prologueDrop=[v2, v3]
  cmp >=Int [v14, v12]
  then
    ...
    op +Int [v13, v4] postDrop=[v4]
  else
    ...
    continue loop [v10, v11]
```

この読み方は次のとおりである。
`loop`自身のパラメータリストには、2エントリ(`v13`/`v14`、つまり`acc`/`n`)しかない。
`tag`(`v0`)と`limit`(`v1`)は、どちらもリストから完全に消えている。
`limit`は、実際にネイティブshadowの対象でありながら、そうなっている(各反復で`cmp >=Int`のオペランドとして読まれるので、第8節の例の`BenchLoop`の`n`と同じである)。
`limit`自身のシャドウ(`v12`)は、代わりにループの直前で1回だけ束縛される。
`let v12 : Native Int = v1`は、その時点でまだ完全にBoxedで、完全に所有されている`v1`を、ネイティブに1回だけ読む。
`drop [v1]`が、直後に元の値を解放する。
ループ本体内の、`limit`のネイティブコンテキストでの読み取り(上の`cmp >=Int [v14, v12]`)は、すべて`v12`を直接使う。
どの反復でも、再読み込みや再アンボックスは行わない。
`tag`(`v0`)は、包む必要がまったくない。
Boxedのままで、`let`の接頭辞にも`loop`自身のパラメータリストにも現れない。
残る使用箇所は基底ケースの`length tag`だけで(上には表示していない)、このパスが走らなかった場合とまったく同様に、ワーカー自身の`v0`引数を直接読む。

## 8.6. ホイスティングされた(ループ不変の)式を読む

パラメータ全体のほかにも、ループ本体自身の*無条件の接頭部*(最初の`case`/`cmp`より前)にある`let`のうち、値がループ外のオペランドしか読まないものは、同じ方法でホイスティングされる。
この`let`は、`loop [...]`の完全に外側へ移動する。
`tests/Test110Loop/LoopInvariantParam.idr`(そのファイルの末尾にマージされた、ループ不変式のホイスティングのカバレッジ)の`bound = limit * 2`を例にとる(どちらも`Native Int`。`limit`自身は、第8.5節のとおり、すでにホイスティングされたネイティブshadowのパラメータである)。

```
let v12 : Native Int =
  v1
drop [v1]
let v3 : Native Int =
  op *Int [v12, #2]
loop ["v9:Native Int", "v10:Native Int"] initial=[v1, v2] prologueDrop=[v1, v2]
cmp >=Int [v10, v3]
...
```

`v3`(`bound`)が`v12`(`limit`)自身の`let`の*内側*に置かれているのは、`v12`を読むからである。
ホイスティングされた式は、それ自身が依存する、ホイスティングされたパラメータ束縛の内側に必ずネストされる。
このようにホイスティングされるのは、`Rep`が`Native`/`RInlineNative`の`let`だけである。
`Boxed`の`let`は、値がループ不変なオペランドしか読まない場合でも、必ず`loop [...]`の内側に残る。
その時点以降の*それ自身の*生存期間が、各反復がどの分岐を通るかに依存しうるからである。
`tests/Test110Loop/LoopInvariantParam.idr`に吸収された、元の`Test21BoxedInvariantNotHoisted.idr`のケースが、まさにこの点の専用の否定テストである。
理由の詳細は`rc2/doc/loop-conversion.md`の「Loop-invariant expression hoisting」の節にある。
この制限を追加するきっかけとなった実際のdouble-freeも、そこに書かれている。

## 8.7. sinkingされた(分岐ローカルな)式を読む

`Compiler.RC2.Sink`(`doc/branch-sinking.md`を参照)は、`Compiler.RC2.Loop`の直後に走る。
そのため、効果はまったく同じダンプに現れる。
`case`/`cmp`の直前にあって、片方のarmでしか読まれない`let`が、代わりにその1つのarmの*内側*へ移動する。
もう片方のarmにあった、その`let`のための不要になった`drop [...]`は消える。
これは、第8.6節のホイスティング(計算をループの*外*へ出す)の鏡像である。
sinkingは、計算を、それを実際に必要とする分岐のarmの*内側*へ入れる。
そのarmに実際に到達したときだけ実行されるので、ホイスティングの「呼び出しごとに無条件で1回」よりも、さらに実行回数が少なくなる。
第8.5/8.6節とは違って、sinkingにはループがまったく不要である。
`tests/Test22BranchSinking.idr`のダンプは、通常の再帰しない関数で、同じ形を示している。
`tests/Test110Loop/LoopInvariantParam.idr`に吸収された、元の`Test21BoxedInvariantNotHoisted.idr`のケースの、`Sink`後のダンプでは、第8.6節が意図的に`loop [...]`の内側に残している`let v5 = ...`に対して、これが働いている。
この束縛に対して、ホイスティングとsinkingは競合せず、補完し合う(`doc/branch-sinking.md`の「Sinking versus hoisting」の節を参照する)。

## 9. 具体例

### constructor-reuse-in-place(`Test111Basics/Basics.idr`の、`List.takeUntil`に似たコード)

```
case v1 of
  _builtin.CONS [cons] tag=Just 1 args=[v2, v3] ->
    reuseOffer v1 dupOnShared=[v2, v3]
    let v4 : Boxed =
      dup v0
      dup v2
      apply v0 v2
    case v4 of
      1 ->
        drop [v0, v3, v4]
        con _builtin.CONS [cons] tag=Just 1 [v2, [__]] reuse=v1
      0 ->
        drop [v4]
        let v5 : Boxed =
          let v6 : Boxed =
            apply v3 [__]
          call Prelude.Types.takeUntil [v0, v6]
        con _builtin.CONS [cons] tag=Just 1 [v2, v5] reuse=v1
```

この読み方は次のとおりである。
`v1`(scrutinee。`Cons`セル)がマッチされ、`v2`/`v3`(head/tail)が、そのストレージから直接分解して取り出される。
直後に`reuseOffer v1 dupOnShared=[v2, v3]`がある。
`v1`はこのaltのどの経路でも死にかけており、どちらの分岐も同じ形の新しい`Cons`を構築する。
そのため、このaltは再利用の対象になった(`doc/reuse-analysis.md`の`resolveAlt`の適格性ルールを参照する)。
実際にこの申し出を受け取るのは、各分岐自身の`con _builtin.CONS ... reuse=v1`である。
実行時には、`idris2rc2_isUnique(v1)`が、この構築で`v1`自身のストレージをその場で再利用するか、新しく割り当てるかを決める。
どちらの場合も、`v2`/`v3`は先に自分の`dup`を必要とする。
ここに別の`dup v2`の行として表示されていないのは、`reuseOffer`自身の`dupOnShared`プロトコルに組み込まれているからである。
実行時のチェックがどちらの経路を選んでも、両方のフィールドが新しい`Cons`に引き継がれる。

### 相互末尾再帰のマージ(`Test110Loop/SelfTailLoop.idr`の`isEvenM`/`isOddM`)

```
def Main.isEvenM  (fun args=[v0])
  call {rc2_mutualLoop:0} [#0, v0]

def Main.isOddM  (fun args=[v0])
  call {rc2_mutualLoop:0} [#1, v0]

def {rc2_mutualLoop:0}  (fun args=[v1, v2])
  loop ["v1:Boxed", "v2:Boxed"] initial=[v1, v2]
  case v1 of
    0 ->
      case v2 of
        0 ->
          drop [v2]
          1
        _ ->
          let v3 : Boxed =
            op -Integer [v2, #1] postDrop=[v2]
          continue loop [#1, v3]
    1 ->
      ...
```

`Main.isEvenM`/`Main.isOddM`は、それぞれ薄いラッパーになった。
合成された`{rc2_mutualLoop:N}`関数への`call`が1つあるだけで、自分自身のタグ(`#0`/`#1`)と、実際の引数を渡している。
マージされた関数自身が、そのタグで分岐する(`case v1 of 0 -> ...isEvenM自身の本体...; 1 -> ...isOddMの本体...`)。
*メンバー間*の遷移(`isEvenM (S k) = isOddM k`)は、`continue loop [#1, v3]`にすぎない。
タグを`1`に切り替えてループするだけで、同じメンバー内の遷移とまったく同じ扱いになる。
これは、`TODO.md`の「Mutual tail recursion loop conversion」の節が述べているものの、具体的な形である。
マージされた関数自身から見れば、自己でもメンバー間でも、すべての遷移が通常の自己末尾呼び出しである。
そのため、`Compiler.RC2.MutualLoop`の直後に走る`Compiler.RC2.Loop`は、特別な場合分けなしにそれを変換できる。

### 比較/分岐の融合(`Char`に対する`Prelude.EqOrd.==`)

```
def Prelude.EqOrd.==  (fun args=[v0, v1])
  cmp ==Char [v0, v1]
  then
    1
  else
    0
```

ここでは、Boxedの`Bool`値は、ネイティブなものも含めて、まったく構築されない。
`cmp ==Char [v0, v1]`は、生のCの`==`を、`1`/`0`のどちらかを選ぶ`if`に直接埋め込んだものである(`alwaysUnboxed`により`Bits8`タグなので、これらもコストがかからない)。
*融合されない*比較と対比してみる。
たとえば`Integer`に対する`Prelude.EqOrd.<`は、`Integer`がネイティブにならないので、Boxedのままである。
`let v2 : Boxed = op <Integer [...] ...`のあとに通常の`case v2 of 0 -> ...; _ -> ...`が続き、Booleanが実際に値として具体化される。

## 10. クイックレシピ

- **「自己末尾再帰の関数が`goto`ループになったか」** -- `grep -A1 "^def YourFn" out.rcexpr`を実行し、すぐ次の行が`loop [...]`かどうかを見る。
- **「特定のループパラメータがネイティブshadow化されたか」** -- 同じ`loop [...]`の行のパラメータリストで、そのパラメータに対応する位置に`Native <ty>`があるかを確認する(`initial=[...]`と照らし合わせる。順序は、関数自身の`args`と同じである)。
- **「このマッチでconstructor-reuseが働いたか」** -- alt自身の分解の直後に`reuseOffer`があるかを探す。そして、対になる`con ... reuse=<同じid>`(申し出が使われた)か`releaseReuse <同じid>`(解放された)を、alt自身の本体のどこかで探す。
- **「これはリークかuse-after-freeか」** -- 第6節の、すべての経路をたどる手法を使う。`postDrop`/`RFree`のフィールドは、過去のバグが潜んでいた場所そのものである(`doc/native-type-inference.md`の「Bugs found」のリストを参照する。回帰テストを書く前に、まさにこの種の手作業のトレースで見つかったものが複数ある)。
- **「`Prelude`/ライブラリの関数Xは、実際には何にコンパイルされるか」** -- ファイル全体を`grep -n "^def "`する。ダンプの対象は、自分のモジュールだけではない。

## 11. 制限(参照のため、第1節から再掲)

- ソースの位置情報(`FC`)は完全に取り除かれる。`RCExp.idr`のすべてのノードがこれを持つが、この目的にはノイズでしかない。
- キーワード(`let`、`case`、`dup`、...)は、意図的に簡潔にしてあり、実際のIdrisのコンストラクタ名では**ない**。`RCExp.idr`に戻る正式な対応表は、第5節である。
- コンパイラ自身が読み戻すことはない。デバッグ専用で、rc2の変更をまたいで形式が変わらない保証はない。
  `tools/rcexpr-lint`(下記)はこれを読み戻すが、それは、その時点の形式がどうなっていようと、それに対して動く外部ツールとしてである。コンパイラ内部の契約ではない。
- 最終的な、Reuse/MutualLoop/Loopが適用済みの状態だけを反映する。それより前のパイプラインのステージが必要なら、第1節を参照する。

## 12. 機械的に確認する: `tools/rcexpr-lint`

第10節の、すべての経路を手でたどる手法は有効だが、遅く、手作業では間違えやすい。
同じ手法で見つけた`Compiler.RC2.Sink`のuse-after-freeは、実際のバグが特定されるまでに、ダンプのトレースに何時間もかかった。
`tools/rcexpr-lint`は、「これはリークかuse-after-freeか」の確認を自動化する。
`.rcexpr`ファイルをパースし(`Language.RCExpr.AST`/`Lexer`/`Parser`。`libs/rc2base`にある、この文法専用の独立したパーサーで、このツール以外でも再利用できる)、各`def`の本体を歩きながら、`Boxed`のローカル変数ごとに生きている参照の数を保持する。
すでに0のものを読んだりdropしたりしたら、それを指摘する。

```sh
cd tools/rcexpr-lint && source ../../env.sh
nix-shell -p gcc gmp pkg-config --run \
  'idris2 -p rc2base -p contrib -o rcexpr-lint RcexprLint.idr'
./build/exec/rcexpr-lint path/to/out.rcexpr
```

異常が見つかると、非ゼロで終了し、1件につき1行を出力する。
正確なルールセットと、既知の範囲の制限は、`Lint.idr`自身のモジュールノートを参照する。
チェックは1種類だけである(use-after-free/double-drop。リークの検出や、分岐間の一貫性は対象外)。
このダンプは、`case` alt自身が束縛する変数の`Rep`を一切表示しないので、そうした変数は、保守的に`Boxed`として扱う。

## 関連ファイル

- `rc2/src/Compiler/RC2/Pretty.idr` -- レンダラー自身(`prettyExp`/`prettyDef`/`prettyProgram`。第5節のすべての構文)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `compileExpr`自身の`--directive dumprcexpr`の配線(`.rcexpr`ファイルを書き出す)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- ここでレンダリングしている実際のIR。上で触れたすべてのコンストラクタに、正式なドキュメントコメントがある。
- `tools/rcexpr-lint` -- 第12節の機械的なチェッカー(`RcexprLint.idr`がCLI、`Lint.idr`がチェック本体)。
- `libs/rc2base/src/Language/RCExpr/` -- `rcexpr-lint`が基づくパーサー(`AST.idr`/`Lexer.idr`/`Parser.idr`)。この形式を読みたい他のツールも再利用できる。
