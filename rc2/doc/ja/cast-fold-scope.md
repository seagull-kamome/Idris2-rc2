# Castの定数畳み込み: 除外した方向とその理由(調査したが、これ以上は見送り)

(原文: `doc/cast-fold-scope.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.ConstFold`の`foldableOp`(自身のドキュメントコメント
参照)は、`Cast`を、両辺が固定幅int/`Integer`のオペランドである場合、
および固定幅int/`Integer` -> `String`の場合にのみ畳み込む。本書は、
さらに3つの方向 -- `Char -> String`、`Double -> String`、および
`String`を発生源とするあらゆる`Cast` -- が調査され、畳み込むのが
安全でないと判明した理由を記録する。将来のセッションが`foldableOp`
に再び触れる前に、これらを再度導出する必要がないように。

## `Char -> String`: `stripQuotes`が複数文字エスケープを誤って扱う

本家の`Core.Primitives.getOp`の`Cast`ディスパッチは発生源の型を無視
し、目的の型だけでディスパッチする(`getOp (Cast _ y) = castTo y`、
`idris2-src/src/Core/Primitives.idr:610`)。`castTo StringType =
castString`(`Primitives.idr:551,563`)であり、`castString`の`Ch`ケース
(`Primitives.idr:42`)は以下の通り:

```idris2
castString [NPrimVal fc (Ch i)] = Just (NPrimVal fc (Str (stripQuotes (show i))))
```

`stripQuotes`(`idris2-src/src/Libraries/Utils/String.idr:10-11`)は
各端からちょうど1文字ずつ取り除く。これは通常の印字可能な文字には
正しい(`show 'A' = "'A'"`は取り除くと`"A"`になる)が、`Show Char`
自身のエスケープ処理(`libs/prelude/Prelude/Show.idr`の
`showLitChar`)は、`'\DEL'`(0x7F)より上の全てのコードポイント、
および`'\n'`のような名前付き制御文字を、**複数文字**のエスケープ
シーケンスとしてレンダリングする: `show '\n' = "'\n'"`(バック
スラッシュ+n、クォート内に2文字)、コードポイント0x3042(`'あ'`)の
`show`も同様に複数文字の数値形式にエスケープされる。`stripQuotes`は
各端から常に1文字しか取り除かないので、そのようなコードポイントに
ついては、結果はエスケープシーケンス自身のテキスト(バックスラッシュ
に続いて`n`など)になってしまい、実際の文字にはならない。
`Compiler.RC2.ConstFold.constFoldOp`は本家の`getOp`を無改造で呼び
出している(再実装なし)ので、`Cast CharType StringType`を畳み込むと
このバグをそのまま引き継ぐことになる -- 手作業で確認済み: `cast
'あ'`が`castString`経由で畳み込まれると、rc2自身のランタイム
(`support/rc2/numeric.c`の`idris2rc2_cast_Char_to_string`、エスケープ
処理を一切行わない単純なコードポイント→UTF8バイト列エンコーダ)が
生成する正しいUTF-8エンコーディングではなく、誤った複数バイトの
エスケープテキストが得られてしまう。

`foldableOp`の`Cast from StringType`ケースは`isJust (intKind
from)`でゲートされており、`intKind CharType = Nothing`なので、この
除外は既に自動的である -- 維持すべき独立した`Cast CharType
StringType = False`節は存在しない。本書が指摘するリスクは、具体的
には、将来の「簡略化」で`Cast from StringType`を汎用の`isJust
(intKind from) && isJust (intKind to)`ルールへ統合しても、それでも
`Char`は(同じ理由で)正しく除外される、ということではなく、誰かが
本家側の根本的な`stripQuotes`バグを修正した(あるいは`castString`の
`Ch`ケースを正しい実装に置き換えた)場合に、rc2がその後
`foldableOp`を拡張しても安全かどうかを一度も再検討しないまま放置
される、という点にある。

テスト: `rc2/tests/Test17ConstFold.idr`の`castCharToStringNotFolded`
は`'あ'`(意図的に非ASCIIのコードポイントを選んでいる、単なる文字
ではない -- もしこの除外がいつか回帰した場合、たまたま一致するの
ではなく、目に見えて誤った文字列が生成されるようにするため)を
castし、ランタイムの出力が正しいUTF-8エンコーディングであることを
検査する。

## `Double -> String`: `%f`とホスト側`Show Double`の書式の不一致

`castString`の`Db`ケース(`Primitives.idr:41`)は`Str (show i)`である
-- ホストのIdris2コンパイラ自身の`Show Double`が生成するもの(可変幅
の書式、例えば`3.000000`ではなく`3.0`)。rc2自身のランタイム
(`support/rc2/numeric.c`のDouble→文字列cast)は`snprintf(..., "%f",
v)`を使い、常に固定6桁の小数(`0.0` -> `"0.000000"`、
`rc2/tests/Test7CastMatrix.expected`と突き合わせ確認済み)になる。
この2つの書式は一致しないので、畳み込みを行うと、コンパイル時に
ランタイムcastが生成するのとは異なる文字列が黙って生成されてしまう。

これは既に別の層で構造的にブロックされている:
`ConstFold.safeConst`は`Db`を(`Cast`だけでなく)*あらゆる*`PrimFn`
から除外している(ホスト側の幅/丸め誤差の不一致リスク、`I`を除外
しているのと同じ理由)ので、`constFoldOp`の`all safeConst cs`検査は、
`foldableOp`が何を言おうと`Cast DoubleType StringType`の畳み込みを
既に拒否している。`foldableOp`自身の`Cast from StringType = isJust
(intKind from)`が2つ目の独立したブロックを加えている
(`intKind DoubleType = Nothing`)。どちらも意図的なものである --
もう一方が唯一のガードとして残っている間は、どちらも除去しない
こと。この方向をいつか見直すなら、まず変更が必要になるのは
`safeConst`の方であり、上記の`%f`対`show`の書式問題を再び開かずには
それを変更できない。

テスト: `Test17ConstFold.idr`の`castDoubleToStringNotFolded`。

## `Cast`の発生源としての`String`(どちらの方向でも): パーサの意味論が未検証

`Core.Primitives.getOp`の`Cast`ディスパッチは、いくつかの目的型に
ついて`String`を*発生源*として受け付けてもいる -- `castInteger`/
`castInt`/`castDouble`(`Primitives.idr:58,73,140`)はいずれも`Str`
ケースを持ち、ホスト自身の`Prelude.Cast String X`インスタンス
(`prim__cast_StringInteger`など、バックエンド定義のプリミティブ)
経由で文字列をパースする。そのパーサが、rc2自身のランタイム
パーサ(`support/rc2/numeric.c`の`mpz_set_str`/`atoll`/`atof`ベースの
`String -> Integer/Int*/Double`cast、いずれも不正な入力に対する明示
的なエラー処理を行わない)とバイト単位で一致するかどうかは未検証
である -- そして、このエコシステム内のパーサが必ずしも一致しない
という具体的な証拠が既に存在する: `rc2/tests/Test7CastMatrix.idr`
自身のヘッダコメント(15-19行目)は、rc2の`String -> Int64/Bits64`
castが、同じcastのRefCの`atoi`ベース(そのため32ビット制限のある)
版を再現するのではなく、意図的に`atoll`経由でパースすることを
記しており、その乖離を検証するのではなくバックエンド間で比較可能
であり続けるために、自身のテスト値を`atoi`の範囲内に意図的に
留めている。もし2つの*ランタイム*C側実装(rc2自身のもの、RefCの
もの)が既に範囲について一致しないのであれば、ホストのIdris2
コンパイラ自身の評価器(それを構築したバックエンドが何であれ、
典型的にはChez)がコンパイル時にどちらかと一致すると仮定する理由
は無い。

また`getOp`自身の`castBits8`/`castInt8`など(固定幅整数の目的型、
`constantIntegerValue`経由、`Primitives.idr:76-87`)には`Str`ケース
が**一切**無いことにも注意 -- `String -> Bits8`の類は、
`foldableOp`が何をしようと関係なく、`getOp`自身から既に`Nothing`を
返す。`getOp`層で実際に生きていて明示的な除外が必要なのは
`String -> Integer/Int(接尾辞なし)/Double`だけであり、`Int`/
`Double`は別の根拠で既に除外されている(`Cast _ IntType = False`、
`intKind DoubleType = Nothing`)。`String -> Integer`は、`getOp`層で
生きていてかつ他の理由では除外されていない唯一の組み合わせなので、
`foldableOp`の汎用ルール`Cast from to = isJust (intKind from) &&
isJust (intKind to)`は今日のところこれを正しく処理している
(`intKind StringType = Nothing`) -- ただし、上記の`Char`のケースと
同じ注意点として、これは`intKind`の現在の定義の副産物であって、
手で保守されている安全性チェックではないので、`intKind`や汎用
ルールの形がいつか変わった場合にも除外され続けると仮定しないこと。

テスト: `Test17ConstFold.idr`の`castStringToIntegerNotFolded`。

## ファイル

- `rc2/src/Compiler/RC2/ConstFold.idr` -- `foldableOp`自身のドキュメント
  コメントが、この理由付けの短縮版を持つ。本書はその完全版である。
- `idris2-src/src/Core/Primitives.idr` -- `castString`/`castTo`/
  `castInt`/`castInteger`/`castDouble`、約31-160行目、550-613行目。
- `idris2-src/libs/prelude/Prelude/Show.idr` -- `Show Char`自身の
  複数文字エスケープ(`showLitChar`)。
- `idris2-src/src/Libraries/Utils/String.idr` -- `stripQuotes`。
- `rc2/support/rc2/numeric.c` -- rc2自身のランタイムCast実装
  (`idris2rc2_cast_Char_to_string`、Double→文字列の`%f`書式、
  `String -> Integer/Int*/Double`パーサ)。
- `rc2/tests/Test7CastMatrix.idr` -- ヘッダコメントが、この領域を
  調査中に見つかった`atoll`対`atoi`のString発生源の乖離と、
  3つの無関係な本家RefCランタイムのバグ(`idris2_cast_Double_to_Int8`
  が完全に欠落、`idris2_cast_String_to_*`が大文字のSで定義されて
  いるがRefC自身のコンパイラは小文字形式への呼び出しを発行する、
  `idris2_negate_Double`が`idris2_nagate_Double`とタイポされている)
  を記録している -- これらはいずれもrc2側のバグではない。
- `rc2/tests/Test17ConstFold.idr` -- 上記3方向がいずれも畳み込まれ
  ないままであることを確認する回帰テスト。

## 検証方法(これを再び開く場合)

1. **`Char -> String`**: まず本家の`castString`の`Ch`ケース(または
   `stripQuotes`)が複数文字エスケープを正しく扱うよう修正された
   かどうかを確認する。もし修正されていれば、単に`foldableOp`を
   拡張するのではなく、その修正の理由付けを移植する -- `Show Char`
   の現在のエスケープ規則から、ASCIIの印字可能文字だけでなく全ての
   コードポイントが`show`+アンエスケープを経て正しく往復するかを
   再導出すること。
2. **`Double -> String`**: これはプロジェクト全体にわたる
   `safeConst`の`Db`除外(`Cast`だけでなく全ての`PrimFn`から`Db`を
   除外している)を先に見直さない限り進められない -- それはより
   大きな、別の意思決定である。もし取り組むなら、境界値の掃引
   (0.0、負のゼロ、非常に大きい/小さい絶対値、片方の書式でのみ
   科学的記数法が必要になる値)にわたって`snprintf("%f", ...)`の
   出力をホスト自身の`Show Double`の出力と突き合わせ、単一の例を
   信頼する前に検証すること。
3. **`String -> Integer`**: rc2の`mpz_set_str`ベースのランタイム
   パースと、同じリテラルのコンパイル時`getOp`畳み込みの両方を、
   不正な/エッジケースの入力(先頭の`+`、空白、先頭のゼロ、空
   文字列、オーバーフロー)にわたって -- 整形式の10進整数だけでなく
   -- 検証する再現コードを書き、`intKind`ベースの汎用的な除外が
   `intKind`の定義がいつか変わっても動作し続けると信頼する前に、
   両者が一致することを確認すること。
4. `--directive dumprcexpr`(`rc2/doc/reading-the-ir.md`参照)を任意の
   再現コードに対して使うと、ある`Cast`が畳み込まれたか
   (`RPrimVal`)、それともランタイムの`op cast-...`のままかを確認
   できる -- 生成されたCを読まずに`foldableOp`の実際の挙動を確認
   する最速の方法。
