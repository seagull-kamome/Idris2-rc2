# rc2のIRを読む: `--directive dumprcexpr`ダンプと`RCExp`構文

rc2独自の参照カウント付きIR(`Compiler.RC2.RCExp` -- `Compiler.RC2.Emit`
が直接Cへ下ろす木そのもの)をダンプ・読解するための実用リファレンス。
生成されたCコードを読んだり、Idrisソースから逆算したりせずに「rc2が
ここで実際に何を決定したか」を知りたいときに使う。`doc/reuse-analysis.md`
/`doc/native-type-inference.md`の姉妹文書(あちらは各パスが*なぜ*その
決定を下すのかを説明する文書、こちらは全パスが終わった*結果を読む*
ことと、それを見せてくれるツールについての文書)。

(原文: `doc/reading-the-ir.md`。内容が乖離した場合は原文を正とする。)

## 1. IRをダンプする

```sh
cd rc2 && source ../env.sh
nix-shell -p gcc gmp pkg-config --run \
  './build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr YourFile.idr -o out'
```

これにより、生成される`out.c`と同じ場所(`-o`が解決するディレクトリ
-- `idris2-rc2`を起動したディレクトリ配下の`build/exec/`。`.c`や
実行ファイルと同じ場所)に`out.rcexpr`が書き出される。`--directive`は
本家Idris2自身が持つ汎用の実行ごとの文字列パススルー機構(Chez/ESの
directive群と同じ仕組み)であり、これを使うためにidris2-src側への
変更は一切不要だった(`Compiler.RC2.RC2`の`compileExpr`参照)。

他の`idris2-rc2`フラグ(`-p`や`--cg rc2`自体など)と自由に組み合わせて
良い。ダンプの有無はコンパイル内容やプログラムの挙動に一切影響しない
-- 純粋な副作用として、`generateCSourceFile`がこれから消費するのと
*全く同じ*`defs`の値を`prettyProgram defs`でファイルへ書き出すだけ。

**どの時点のパイプライン状態を見ているか**: このダンプは、無効化
されていない`toRCDefs`の全ステージが実行し終わった*後*に発火する
-- `generateCSourceFile`がこれから消費するのとまさに同じ`defs`:

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (プログラム全体のインライン化、Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF風正規化、ネイティブ型推論)
  -> Compiler.RC2.RC.annotate     (Phase 2: 所有権 -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (コンストラクタのin-place再利用)
  -> Compiler.RC2.ConAltNative    (ネイティブshadowフィールドキャッシュ)
  -> Compiler.RC2.MutualLoop      (相互末尾再帰 -> 合成関数へマージ)
  -> Compiler.RC2.Loop            (自己末尾呼び出し -> RLoop/RLoopContinue)
  -> Compiler.RC2.Sink            (枝ローカルなsinking、doc/branch-sinking.md参照)
  -> Compiler.RC2.DualABI         (worker/wrapper合成、呼び出しサイト書き換え)
  -> [ ここで .rcexpr がダンプされる ]
  -> Compiler.RC2.Emit            (RCExp -> C、純粋に機械的な変換)
```

-- つまり見えているのは`Emit.idr`が実際に消費する内容そのもの
(全ての所有権判断、全ての再利用オファー、全てのループ変換、そして
全てのデュアルABI worker/wrapper書き換えが既に確定済み)。現時点
では、もっと*前段階*(たとえばPhase 1直後、所有権が決まる前)を
ダンプするフックは存在しない。必要なら`compileExpr`と同様の
パターンで、関心のある時点に同様の`writeFile`呼び出しを追加すれば
よい。

**1ファイル・プログラム全体分**: ダンプには、`Compiler.RC2.RC2`の
`toRCDefs`が生成したトップレベル定義1つにつき1つの`def`ブロックが
含まれる -- 自分のモジュールの定義だけでなく、推移的に到達可能な
`Prelude`/ライブラリ関数(`Prelude.EqOrd.==`、`Prelude.Show.show`、...)
も全て含む。これはしばしば望ましい挙動そのものだが(例えば`Int`の
`==`インスタンス自体がどうコンパイルされるか見たい場合など)、
ファイルが大きくなることは意味する。まず`grep -n "^def "`で目的の
定義を探すとよい。

**注意点**: あくまでデバッグ補助であり、(`.ttc`と違って)コンパイラ
自身が読み戻すことは一切ない。rc2のバージョン間での形式安定性も
保証していない -- 完全性より読みやすさを優先した表記選択になっている
(`Compiler.RC2.Pretty`自身のモジュールコメント参照: ソース位置情報は
完全に省かれ、各コンストラクタには本来のIdrisコンストラクタ名ではなく
短いキーワードが割り当てられている -- その対応表がまさに以下の
第3節の内容そのもの)。`.rcexpr`ファイルは生成された`.c`と同じ場所に
置かれるビルド成果物であり、コミットはされない。必要な都度、再生成
すればよい。

## 2. ダンプ全体の形

`toRCDefs`が生成した順番のまま、定義1つにつき1ブロック:

```
def <Name>  (<種別> ...)
  <本体、インデント済み>

def <Name>  (<種別> ...)
  ...
```

`<種別>`は4種類、`RCDef`の各コンストラクタに対応する:

| ヘッダ | `RCDef` | 意味 |
|---|---|---|
| `(fun args=[v0, v1])` | `MkRCFun` | 通常の関数。本体が1段インデントして続く。 |
| `(con tag=Just 1 arity=2 newtype=Nothing)` | `MkRCCon` | データコンストラクタ自身のメタデータ(本体なし -- コンストラクタは実行されるものではなく、それを構築・照合する側のための記述に過ぎない)。`tag=Nothing`はタグなし(単一コンストラクタ型など)を意味し、`newtype=Just k`はフィールド`k`が実行時表現でありコンストラクタ自体は消去されることを意味する。 |
| `(foreign ["scheme:...", "C:foo,libfoo"] [CFInt, CFString] -> CFIORes CFUnit)` | `MkRCForeign` | FFI宣言: 順に試される呼び出し規約文字列群、引数の`CFType`群、戻り値の`CFType`。 |
| `(error)` | `MkRCError` | Idris2がある種の方法で実行時に先送りした、コンパイルに失敗した定義(稀)。本体はクラッシュ式。 |

さらに本体を持つのは`(fun ...)`/`(error)`だけであり、本書の以降の
節はその本体の読み方についてのもの。

## 3. 値(`RCLocal`)

値を*読む*あらゆる箇所(オペランド、引数、スクルティニー)は
以下の4形式のいずれかとして表示される -- `RCExp.idr`の`Show RCLocal`
そのものであり、至る所に登場するので覚えておく価値がある:

| 構文 | コンストラクタ | 意味 |
|---|---|---|
| `v0`, `v1`, `v42`, ... | `RCLoc n` | 通常のローカル変数: 関数引数、または`let`/パターンマッチ/ループパラメータで束縛されたもの。コンパイラが割り当てた整数で識別される。**IDはパスをまたいで安定でも、1つの定義の中で引数と本体をまたいでも安定でもない** -- 例えばループのネイティブshadow変数は元のパラメータとは別の*新規発行*IDを持つ(第8節参照)。個々の番号自体に「同じ番号=ここでは同じ値」以上の意味を読み取らないこと。 |
| `[__]` | `RCNull` | 文字どおりのC `NULL`。由来は3種類: 消去可能な0引数コンストラクタの値(`Nil`/`Nothing`/`Z`/`MkUnit` -- これらはヒープ確保が一切不要で、NULLか否かだけで照合される)、IOプリミティブ呼び出しを貫く`%World`トークン(`extprim ... [[__], ...]`)、または`Compiler.RC2.MutualLoop`自身がアリティの小さいグループメンバーの未使用末尾スロットに詰めるパディング。 |
| `#0`, `#"hello"`, `#'x'`, ... | `RCConst c` | ネイティブ対応、または安価なリテラルがその場に直接インライン化されたもの。`var_N`もlet束縛も dup/drop も一切ない -- どの定数がこの対象になるかの正確な条件は`doc/native-type-inference.md`の「`RCLocal.RCConst`」節参照。 |
| `#Main.NoShape@1`, `#Prelude.Show.Open@0`, ... | `RCEmptyCon n ci tag` | 上記4つの`RCNull`以外の、0引数だが*タグ付き*のデータコンストラクタ(例えば多コンストラクタ列挙型に対する`f Red`)。`Name@tag`としてタグ付きポインタ定数にインライン化され、ヒープ確保なし。 |

## 4. 表現(`Rep`)

すべての`let`束縛と、すべての`loop`のパラメータリスト自身に表示される:

| 構文 | 意味 |
|---|---|
| `Boxed` | 通常のヒープ確保(またはタグ付きポインタ)された`IDRIS2RC2_Value*`。通常どおり参照カウントされる。 |
| `Native <PrimType>` | スタック上に生きる生のCスカラー(`int64_t`、`double`、`uint8_t`、...)。このローカルに関してはヒープ確保も参照カウントも一切発生しない。`<PrimType>`はIdris2自身の型(`IntType`、`Int64Type`、`Bits8Type`、`DoubleType`、`CharType`、...)。 |
| `InlineNative <PrimType>` | `Native`と同様だが、加えてCの変数宣言すら一切行われない -- 計算式が唯一の使用箇所へ直接埋め込まれる。Phase 2が、そのローカルがBoxedオペランドを一切持たず、かつ使用が1回きりだと判明した時点で、普通の`Native`から昇格させる洗練形。値が`Native`として束縛されている様子は見えるが、そのための`let vN`行はどこにも現れない(そもそも生成されない)。 |

## 5. 式構文の完全リファレンス

`RCExp`の全コンストラクタと、`Compiler.RC2.Pretty`がそれをレンダリング
する簡潔なキーワード。`~<reason>`は「このIdrisの`LazyReason`のもとで
遅延」を意味する任意の接頭辞(`~Rec`、`~Force`、...) -- Idris2が
遅延と印を付けた呼び出し/演算にのみ付き、ほとんどの行では出現しない。

| 構文 | `RCExp` | 意味 |
|---|---|---|
| `v0`(キーワードなし、裸) | `RV` | この式の値はローカル`v0`そのもの、そのまま読む。ある分岐の末尾の値として(`sumTo`のベースケースなど、第8節参照)、他の式の中に埋め込まれるのと同じくらい頻繁に登場する。 |
| `~r call Name [v0, v1]` | `RAppName` | `Name`をこれらの引数で呼び出す。末尾位置(`~`なし)の場合、`Compiler.RC2.Emit`のクロージャ構築ロジックがここを横取りする対象そのもの。それ以外では通常の(トランポリンされる場合もある)呼び出し。 |
| `partial Name missing=1 [v0]` | `RUnderApp` | 部分適用: `Name`にこれらの引数を渡した状態のクロージャを構築する。まだ`missing`個の引数が必要。 |
| `~r apply v0 v1` | `RApp` | *既に構築済みの*クロージャ`v0`をもう1つの引数`v1`に適用する(トップレベル関数を直接名指しする`call`との違い)。 |
| `let v0 : Boxed =`<br>`  <value>`<br>`<body>` | `RLet` | `v0`(表示された`Rep`で)を`<value>`の結果に束縛し、続けて`<body>`へ進む。最も頻出するラッパー -- ほぼ全ての中間計算がこれを経由する。 |
| `con Name ConInfo tag=Just 1 [v0, v1]` | `RCon` | `Name`の値をこれらのフィールドで構築する。`ConInfo`はIdris2自身が持つ「ソースレベルでどの種類のコンストラクタか」を表す短いタグ(リスト状の型には`[cons]`/`[nil]`、通常のコンストラクタには`[data]`、`[record]`、`Nat`状の型には`[zero]`/`[succ]`、`[enum N]`、`[unit]`、`[just]`/`[nothing]`、...)。`tag=Nothing`はタグなし(単一形状の型)を意味する。末尾の`reuse=v2`は、この構築が`v2`自身のストレージをin-placeで再利用する可能性があることを意味する -- 第9節の再利用の実例参照。 |
| `op PrimFn [v0, v1] postDrop=[v0]` | `ROp` | プリミティブ演算(`+Int`、`-Integer`、`cast-Integer-Int`、`==Char`、...)。`postDrop=[...]`が存在する場合、この演算が読み終えた時点でdropが必要な*Boxed*オペランドを列挙する -- 演算自身はオペランドを読むと同時に結果を生成するため、通常の`drop`をラップできる独立した文の位置が存在せず、この場所に代わりに保持している(`doc/native-type-inference.md`参照)。この行が生成時に生のC式になるかBoxedなランタイム呼び出しになるかは、この行自体には現れない*外側*の`let`の`Rep`次第。 |
| `extprim Name [[__], v0, v1]` | `RExtPrim` | rc2自身のランタイムプリミティブ用グルーへの呼び出し(`IORef`、配列、FFIヘルパーラッパー、`%World`を貫くIOプリミティブ -- 第1引数は`[__]`(`%World`トークン)であることが非常に多い)。 |
| `cmp PrimFn [v0, v1] postDrop=[...]`<br>`then`<br>`  <T>`<br>`else`<br>`  <F>` | `RCmpCase` | ネイティブ比較(`LT`/`GT`/`EQ`/`LTE`/`GTE`)が*直接*二分岐に融合されたもの -- Bool結果は(ネイティブとしてすら)一切値として実体化しない。ある比較が、Idris2自身の`Bool`(`False=0`/`True=1`)表現に対する二分岐の唯一かつ直接のスクルティニーになっている場合にのみ生成される。第9節の実例参照。 |
| `case v0 of`<br>`  Name ConInfo tag=Just 1 args=[v1, v2] ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConCase` | スクルティニー`v0`のコンストラクタタグで分岐する。`args=[...]`はこの枝が`v0`自身のストレージから*直接*destructureするフィールド(ポインタのエイリアシングであって、独立に参照カウントされているわけではない -- `v0`が死ぬ前にこれらが`dup`される様子は第9節参照)。`_ ->`は任意のデフォルト(カバレッジが既にデフォルトなしで網羅されていれば、そもそも存在しない)。 |
| `case v0 of`<br>`  0 ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConstCase` | スクルティニー`v0`の*値*をリテラル定数と照合して分岐する(コンストラクタタグではなく、整数スイッチや`String`/`Double`の等値チェイン)。 |
| `0`, `"hi"`, `'x'`(裸) | `RPrimVal` | それ自身がリテラル値であるもの(オペランド参照であってlet/確保が一切ない`#c`/`RCConst`との違いに注意 -- `RPrimVal`は、リテラルが実際に*独自のBoxedな実体*を必要とする場合に合成`let`が束縛する対象、例えばファイルスコープの定数へステージされる場合など)。 |
| `erased` | `RErased` | Idris2自身の多重度解析が「一切検査されない」と証明した値。計算するものも表現するものもない。 |
| `crash "msg"` | `RCrash` | 到達不能パス(例えばIdris2が別の方法で網羅的だと証明した`case`)、または明示的なランタイムパニック。`abort()`風の呼び出しに変換される。 |
| `dup v0`<br>`<body>` | `RDup` | `v0`の参照カウントを増やす(「参照を1つ追加する」)、その後続行 -- 借用による使用がこれに変換される。 |
| `drop [v0, v1]`<br>`<body>` | `RDrop` | 列挙された各ローカルの参照カウントを減らす(0になれば再帰的に解放)、その後続行。最も頻出する所有権クリーンアップの形。`Compiler.RC2.RC`の`annotate`は、ある分岐の入口にこれをたかだか1つだけラップする。 |
| `free v0`<br>`<body>` | `RFree` | `v0`を今すぐ*無条件に*、チェックなしで解放する -- 参照カウントの確認は一切しない。`annotate`が束縛の形だけから「`v0`は共有される機会が一切なかった、生成されたばかりのヒープ確保である」と証明できた場合にのみ挿入される(`drop`がするはずの分岐とメモリ読み取りを省略できる)。実際にはまれ -- 詳細は`doc/native-type-inference.md`または`RCExp.idr`自身のモジュールコメント参照。 |
| `releaseReuse v0`<br>`<body>` | `RReleaseReuse` | 再利用予約(次の行参照)を解放する。このパス上では結局消費されなかった場合。 |
| `reuseOffer v0 dupOnShared=[v1, v2]`<br>`<body>` | `RReuseOffer` | 実行時の一意性チェック: `v0`が唯一の参照だと判明すれば、同じ木の中の後続の`con ... reuse=v0`のためにそのストレージが予約される。そうでなければ`dupOnShared`の各フィールドが追加の参照を得(`v0`自身の通常の再帰的dropを生き延びようとしているため)、`v0`は通常どおりdropされる。第9節参照。 |
| `loop ["v4:Native Int", "v5:Native Int"] initial=[v0, v1]`<br>`<body>` | `RLoop` | 自己末尾再帰、または(`MutualLoop`によるマージ後の)相互末尾再帰ループ全体。各ループパラメータ自身のIDと`Rep`。`initial`が各パラメータの開始値を与える(同じ順序、*外側の*スコープで一度だけ評価され、ループが初めて実行される前に渡される)。第8節参照。 |
| `continue loop [v2, v3]` | `RLoopContinue` | 最も近い外側の`loop`の先頭へ、これらを各パラメータの新しい値として渡して戻る -- 位置対応、その`loop`自身のパラメータリストと同じ順序。素のCの`goto`に変換される。 |

分岐(alt)構文(`case`の中で使われる。1行 + インデントされた本体、
枝ごとに1つ):

| 構文 | 意味 |
|---|---|
| `Name ConInfo tag=Just 1 args=[v1, v2] ->` | `RConAlt` -- `RConCase`のスクルティニーをこのコンストラクタと照合し、そのフィールドを列挙された新規IDへ束縛する。 |
| `<constant> ->` | `RConstAlt` -- `RConstCase`のスクルティニーをこのリテラル値と照合する。 |
| `_ ->` | どちらのcase種別についても任意のデフォルト/フォールスルー(それ自体は「alt」ではないため、1段深いインデント)。 |

## 6. 所有権を一目で読む

木の他の場所での局所変数の*使用*は全て、裸の、注釈なしの
`vN`/`[__]`/`#c`である -- 参照カウントの調整は決して暗黙には
行われず、常にその前の独立した行(`dup`/`drop`/`free`)として、
または演算自身のオペランドに限っては`postDrop=[...]`フィールドと
して現れる(演算はオペランドを読むのと結果を生成するのを同じ瞬間に
行うため、読み取りをラップする独立した文の位置が存在しない)。ある
ローカル`vN`が正しく扱われているか監査するには:

1. それが束縛された場所を見つける(`let vN : ...`行、または
   `fun args=[...]`/`RConAlt args=[...]`/`loop [...]`のリストへの
   出現)。
2. そこから到達可能な全てのパスを前方へたどり、あらゆる裸の使用、
   あらゆる`dup vN`、あらゆる`drop [..., vN, ...]`/`free vN`
   (`postDrop`内も含む)を記録する。
3. 所有された値であれば、どのパスでも*ちょうど1つ*の最終的な処遇に
   到達するはず: 呼び出し/戻り値に消費される(dropは不要、所有権が
   移譲される)か、ちょうど1回dropまたはfreeされるか。唯一のdropの
   後に使用がある、または2回のdropの間に再取得(`dup`)がない、と
   いったパスは実際のバグである(これはまさに`doc/native-type-inference.md`
   の「発見したバグ」節に記録されている複数のリーク・
   use-after-freeを発見した手作業の手法そのもの)。

再利用プロトコル(`reuseOffer`/`con ... reuse=sc`/`releaseReuse`)は
単純な直線的な線形パターンではなく三者間の受け渡しである -- 第9節で
実例を最初から最後まで追う。

## 7. 自己末尾呼び出しがループになったかどうかを読む

本体が`loop [...] initial=[...]`で始まる定義は、少なくとも1つの
自己(または、マージ後は相互メンバー間の)末尾呼び出しが`goto`へ
変換されたことを意味する。その内部の`continue loop [...]`はそれぞれ
そうやって変換された呼び出し箇所である。逆に、末尾位置に通常の
`call SameName [...]`が*まだ*残っている定義(相互再帰の場合は、
自分自身がメンバーではない`{rc2_mutualLoop:N}`マージ済み関数を
通常のクロージャ/`call`経由で名指ししている場合)は変換*されていない*
-- 依然として通常のクロージャ構築+トランポリン経路を通る。
`Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`への変更の前後で「この
定義の本体は`loop`で始まるか」を比較するのが、生成Cを見るより先に、
特定の再帰関数がこの最適化に実際に該当するかどうかを確認する最速の
方法。

## 8. ネイティブshadow化されたループパラメータを読む

`loop`自身のパラメータリストは、各パラメータの`Rep`を直接示す:
`"v0:Boxed"`は外側の関数自身の呼び出し規約とまったく同じくBoxedの
まま。`"v4:Native Int"`はこのループパラメータが新規のネイティブ
shadow変数へ昇格されたことを意味する -- ループ突入時に(`initial`の
対応する、依然Boxedな値から)一度だけunboxされ、ループの生存期間
*全体*を通じて生のスカラーとして使われ、ループ内のBoxedコンテキスト
での使用(コンストラクタのフィールド、ネイティブを意識しない関数
への呼び出し、ループの最終的なBoxedな戻り値など)が必要とする場合
にのみ再びbox化される。重要なのは、shadow自身のIDは*元の*パラメータ
のIDと**異なる**という点 -- `initial`は依然として*元の*(常にBoxedな)
引数のIDを列挙しており、`loop`自身のパラメータリストはその隣に
*新規発行*のshadow IDを、位置対応で示している。

実例 -- `BenchLoop.idr`の`sumTo acc n = sumTo (acc + n) (n - 1)`:

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

読み方: 関数自身のトップレベル引数は`v0`(`acc`)/`v1`(`n`)(外部呼び出し
規約により常にBoxed -- `TODO.md`の「デュアル呼び出し規約」ギャップ
参照)。ループはこれらを新規のネイティブshadow`v4`/`v5`でラップし、
突入時に`v0`/`v1`から一度だけunboxする(このunbox自体は関数入口の
通常のステップに過ぎず、この`loop`行には現れない -- Emit時にのみ
現れる)。ループ本体内の全ての参照は`v4`/`v5`を直接読み書きし、
`v0`/`v1`には二度と触れない -- カウントダウンの判定
(`case v5 of 0 -> ...`)も算術(`op +Int [v4, v5]`、`op -Int [v5, #1]`)
も、どちらも純粋なネイティブ演算で、Boxedな中間値は一切ない。
`continue loop [v2, v3]`は次の反復の値を位置対応で渡す(`v2` ->
`v4`のスロット、`v3` -> `v5`のスロット)。ベースケース`0 -> v4`は
shadowをそのまま返す(生成時に、関数自身の戻り値型がBoxedなので
外に出る際にbox化される)。ループ本体には`dup`/`drop`/`free`が
一切現れない -- ネイティブ値には一切不要だから(この結果として得られる
生成Cコード・実測時間の比較は`rc2/BENCHMARKS.md`の2026-08-14付の節、
実世界コードでこの仕組みが*届かない*パターン(コンストラクタでラップ
されたループ内蓄積値)については`TODO.md`の「Native-shadow eligibility
stops at bare top-level scalars」の注記を参照)。

## 8.5. 除去された(ループ不変な)パラメータを読む

`loop`自身のパラメータリストが、囲む関数自身のトップレベル引数
1つにつき1エントリを持つとは限らない。`Compiler.RC2.Loop`の
`applyLoop`は、全てのパラメータについて、本体中の*全ての*
`continue loop`がそれを完全に変更なしで供給しているか(見た目が
等しいだけの再計算ではなく、まさに同一のローカル)を検査する --
そうであるものは、どの反復をまたいでも決して再代入されないことが
証明されているので、理由なく`goto`のたびに持ち運ぶのではなく、
`loop`自身のパラメータリストと`initial`から丸ごと除去される。

そのパラメータが次にどうなるかは、それがネイティブshadow適格
だったかどうかで決まる:

- **Boxedのまま**: 他には一切何も変わらない -- 自身の元のIDは今も、
  そして引き続き、囲む関数自身のトップレベル引数であり、ループ本体
  のどこからでも、このパスが実行される前と全く同じように直接読める。
- **ネイティブshadow適格だった場合**: `loop`の*外側*に置かれる、
  一度限りの`let`+`drop`のペアへホイストされる -- 第9節の下記
  `Compiler.RC2.ConAltNative`の例が、destructureされたフィールド
  自身のネイティブ読み取りをキャッシュするために使っているのと
  まったく同じイディオムを再利用したもの(`Compiler.RC2.Loop`自身の
  `applyLoop`がこれをそのまま再利用し、1つのalt自身の本体ではなく
  ループ全体をラップする)。

実例 -- `Test19LoopInvariantParam.idr`の`sumWithTag tag limit acc n =
if n >= limit then acc + cast (length tag) else sumWithTag tag limit
(acc + n) (n + 1)`(`tag : String`と`limit : Int`はどちらも全ての
再帰呼び出しを通じて完全に変更なしで糸通しされ、実際に変化するのは
`acc`/`n`だけ):

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

読み方: `loop`自身のパラメータリストにはエントリが2つしかない
(`v13`/`v14`、`acc`/`n`) -- `tag`(`v0`)と`limit`(`v1`)はどちらも
完全にそこから消えている、たとえ`limit`が本物のネイティブshadow
適格であっても(毎回の反復で`cmp >=Int`のオペランドとして読まれる、
第8節の`BenchLoop`自身の`n`の例と同じ)。`limit`自身のshadow
(`v12`)は代わりにループの直前でただ一度だけ束縛される --
`let v12 : Native Int = v1`は`v1`(その時点ではまだ完全にBoxedで、
まだ完全に所有されている)をちょうど一度だけネイティブに読み、
`drop [v1]`が直後に元の値を解放し、ループ本体内での`limit`への
ネイティブコンテキストの読み取り(上記の`cmp >=Int [v14, v12]`)は
どの反復でも`v12`を直接使い、二度と再読み込みや再unbox化はしない。
`tag`(`v0`)はラップが一切不要 -- Boxedのまま、`let`前置部分にも
`loop`自身のパラメータリストにも現れず、残る唯一の使用(上記には
示していないベースケースの`length tag`)は単にworker自身の`v0`引数
を直接読むだけで、このパスが一度も実行されなかったかのようになる。

## 8.6. ホイストされた(ループ不変な)式を読む

パラメータ全体だけでなく、ループ本体自身の*無条件prefix*
(最初の`case`/`cmp`より前)に座る`let`で、その値がループ外部の
オペランドしか読まない場合も同様にホイストされ、`loop [...]`の
完全に外側に出る -- `tests/Test20LoopInvariantExpr.idr`の
`bound = limit * 2`(どちらも`Native Int`、`limit`自体は第8.5節に
従って既にホイストされたネイティブshadowパラメータ):

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

`v3`(`bound`)は`v12`(`limit`)自身の`let`の*内側*に座る -- `v12`を
読むから。ここでの順序は常に、ホイストされた式を、それ自身が依存
しているホイスト済みパラメータ束縛の内側にネストする。この形で
ホイストされるのは`Native`/`RInlineNative`な`Rep`の`let`だけ --
`Boxed`なものは、その値がループ不変なオペランドしか読まない場合
でも常に`loop [...]`の内側に留まる。なぜなら、その*自身*の、その
先での生存は、ある反復がどちらの枝を取るかに依然として依存しうる
から(`tests/Test21BoxedInvariantNotHoisted.idr`はまさにこれの
専用の負のケーステスト -- 完全な理由付け、この制限を追加して修正
した実際の二重解放も含めて、`rc2/doc/loop-conversion.md`の
「ループ不変式のホイスティング」節参照)。

## 8.7. 沈められた(枝ローカルな)式を読む

`Compiler.RC2.Sink`(`doc/branch-sinking.md`参照)は
`Compiler.RC2.Loop`の直後に実行されるので、その自身の効果は
まさに同じダンプに現れる: かつて`case`/`cmp`の直上に座っていて
その枝のうち1つでしか読まれない`let`が、その1つの枝の*内側*へ
代わりに移動し、それを必要としなくなったもう一方の枝自身の
`drop [...]`は消える。第8.6節のホイスティング(計算をループの
*外へ*動かす)のちょうど鏡像 -- こちらは計算を、実際にそれを必要と
する1つの枝の中へ*動かし*、実行頻度をさらに減らす(ホイスティング
の「呼び出しごとに一度、無条件で」に対して、「その枝が実際に
到達された場合のみ」)。第8.5/8.6節とは異なり、これにはループが
一切不要 -- `tests/Test22BranchSinking.idr`自身のダンプは、通常の
非再帰関数の中で全く同一の形を示す。`tests/
Test21BoxedInvariantNotHoisted.idr`自身の`Sink`実行後のダンプは、
第8.6節が上で意図的に`loop [...]`の内側に残した、まさにその
`let v5 = ...`に対してこれが発火する様子を示す(そのまさに同一の
束縛について、ホイスティングとsinkingは競合するのではなく補完
し合う -- `doc/branch-sinking.md`自身の「Sinking versus hoisting」
節参照)。

## 9. 実例で読む

### コンストラクタのin-place再利用(`Test1Basics.idr`の`List.takeUntil`風コード)

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

読み方: `v1`(スクルティニー、`Cons`セル)が照合され、`v2`/`v3`
(head/tail)がその自身のストレージから直接destructureされる。
`reuseOffer v1 dupOnShared=[v2, v3]`が直後に続く -- `v1`はこの枝の
*どのパスでも*ここで死ぬことになり、かつ両方の分岐が同じ形の
新しい`Cons`を構築するので、この枝は再利用の対象として適格になった
(適格性の判定ルールは`doc/reuse-analysis.md`の`resolveAlt`参照)。
各分岐の`con _builtin.CONS ... reuse=v1`が実際にオファーを claim する
箇所 -- 実行時に`idris2rc2_isUnique(v1)`が、その構築が`v1`自身の
ストレージをin-placeで再利用するか、新規に確保するかを決定する。
どちらにせよ`v2`/`v3`はあらかじめ独自の`dup`が必要だった(ここでは
独立した`dup v2`行としては現れておらず、`reuseOffer`自身の
`dupOnShared`プロトコルに畳み込まれている -- ランタイムチェックが
どちらのパスを取ろうと、両フィールドとも新しい`Cons`まで生き延びる)。

### 相互末尾再帰、マージ後(`Test9SelfTailLoop.idr`の`isEvenM`/`isOddM`)

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

`Main.isEvenM`/`Main.isOddM`はそれぞれ薄いラッパーになった -- 合成
された`{rc2_mutualLoop:N}`関数を、自分自身のタグ(`#0`/`#1`)と実際の
引数を添えて1回`call`するだけ。合成関数自身はそのタグで分岐する
(`case v1 of 0 -> ...isEvenMの本体...; 1 -> ...isOddMの本体...`)。
*メンバーをまたぐ*遷移(`isEvenM (S k) = isOddM k`)は単に
`continue loop [#1, v3]` -- タグを`1`に切り替えてループするだけで、
同一メンバー内での遷移と全く同じ均一な形。これはまさに`TODO.md`の
「相互末尾再帰のループ変換」節が説明する具体的な形にほかならない:
合成関数自身の視点からは、あらゆる遷移(メンバー内・メンバー間を
問わず)は単なる通常の自己末尾呼び出しに過ぎず、`Compiler.RC2.Loop`
(`Compiler.RC2.MutualLoop`の直後に実行される)は一切の特別扱いなしに
それを変換する。

### 比較/分岐融合(`Char`に対する`Prelude.EqOrd.==`)

```
def Prelude.EqOrd.==  (fun args=[v0, v1])
  cmp ==Char [v0, v1]
  then
    1
  else
    0
```

ここではBoxedな`Bool`値がネイティブ表現も含め一切構築されない --
`cmp ==Char [v0, v1]`は、`1`/`0`のどちらを選ぶかの`if`へ直接埋め込
まれた生のC `==`である(`1`/`0`自体も`alwaysUnboxed`に該当する
`Bits8`タグ付きポインタなので、これ自体も無コスト)。融合されて
いない比較(例えば`Integer`は決してネイティブ対応にならないため
融合されない`Prelude.EqOrd.<`)と対比してみると: `let v2 : Boxed =
op <Integer [...] ...`に続いて通常の`case v2 of 0 -> ...; _ -> ...`
という形になる -- こちらでは真にBoolean値が値として実体化している。

## 10. 早見レシピ

- **「自分の自己末尾再帰関数は`goto`ループになったか?」** --
  `grep -A1 "^def YourFn" out.rcexpr`し、次の行が`loop [...]`に
  なっているか確認する。
- **「特定のループパラメータはネイティブshadow化されたか?」** --
  同じ`loop [...]`行自身のパラメータリストで、目的のパラメータに
  対応する位置に`Native <ty>`があるか確認する
  (`initial=[...]`と、関数自身の`args`と同じ順序で突き合わせる)。
- **「この照合でコンストラクタの再利用が発火したか?」** -- 枝の
  destructure直後の`reuseOffer`を探し、対になる`con ... reuse=<同じID>`
  (claimされた)または`releaseReuse <同じID>`(解放された)をその枝の
  本体のどこかで見つける。
- **「これはリーク/use-after-freeか?」** -- 第6節の「全パスを追う」
  手法。`postDrop`/`RFree`フィールドこそがまさに過去のバグが隠れて
  いた場所(`doc/native-type-inference.md`の「発見したバグ」一覧参照
  -- いくつかはリグレッションテストを書くより前に、まさにこの種の
  手作業のトレースによって発見された)。
- **「`Prelude`/ライブラリ関数Xは実際何にコンパイルされるか?」** --
  ファイル全体を`grep -n "^def "`する。ダンプは自分のモジュールに
  限定されていない。

## 11. 制限事項(第1節の繰り返し、参照用)

- ソース位置情報(`FC`)は完全に省かれる -- `RCExp.idr`の各ノードは
  それぞれ1つ持っているが、この目的には純粋なノイズでしかない。
- キーワード(`let`、`case`、`dup`、...)は意図的に簡潔にしてあり、
  実際のIdrisコンストラクタ名では**ない** -- 第5節が`RCExp.idr`への
  正式な対応表。
- コンパイラ自身が読み戻すことは一切ない。あくまでデバッグ補助であり、
  rc2の変更をまたいだ形式の安定性は保証されない。
- 最終的な、完全にReuse化/MutualLoop化/Loop化された状態のみを
  反映する -- もっと前段階が必要な場合は第1節を参照。

## ファイル

- `rc2/src/Compiler/RC2/Pretty.idr` -- レンダラー本体
  (`prettyExp`/`prettyDef`/`prettyProgram`、第5節の構文は全てここ)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `compileExpr`自身の
  `--directive dumprcexpr`配線(`.rcexpr`ファイルを書き出す)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- ここでレンダリングされている
  実際のIRそのもの。上記で触れた各コンストラクタの正式なドキュメント
  コメントを持つ。
