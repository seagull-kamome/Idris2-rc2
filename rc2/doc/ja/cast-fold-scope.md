# Castの定数畳み込み: 対象から外した方向とその理由(調査したが、これ以上は進めない)

(原文: `doc/cast-fold-scope.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.ConstFold`の`foldableOp`(その本体のドキュメントコメントも参照)が畳み込む`Cast`は、両辺が固定幅整数または`Integer`のものと、固定幅整数・`Integer`から`String`へのものだけである。本書は、さらに3つの方向、すなわち`Char -> String`、`Double -> String`、および`String`を変換元とするすべての`Cast`について、調べた結果畳み込みが安全でないと分かった理由を記録する。将来`foldableOp`に手を入れるときに、同じ調査をやり直さずに済ませるためである。4つ目の節では逆に、`Double`の算術演算と`int -> Double`を扱う。これらは畳み込んで安全だが、`safeConst`が`Db`を一律に除外しているために、現在は畳み込まれていない。

## `Char -> String`: `stripQuotes`が複数文字のエスケープを正しく扱えない

上流の`Core.Primitives.getOp`における`Cast`の振り分けは、変換元の型を見ずに、変換先の型だけで決まる(`getOp (Cast _ y) = castTo y`、`idris2-src/src/Core/Primitives.idr:610`)。`castTo StringType = castString` (`Primitives.idr:551,563`)であり、`castString`の`Ch`のケース(`Primitives.idr:42`)は次のとおりである。

```idris2
castString [NPrimVal fc (Ch i)] = Just (NPrimVal fc (Str (stripQuotes (show i))))
```

`stripQuotes`(`idris2-src/src/Libraries/Utils/String.idr:10-11`)は、両端からちょうど1文字ずつ取り除く。印字可能な普通の文字なら、これで正しい結果になる(`show 'A' = "'A'"`から`"A"`が得られる)。しかし`Show Char`のエスケープ処理(`libs/prelude/Prelude/Show.idr`の`showLitChar`)は、`'\DEL'`(0x7F)より大きいコードポイントをすべて、また`'\n'`のような名前付きの制御文字を、**複数文字**のエスケープ列として出力する。たとえば`show '\n' = "'\n'"`で、引用符の内側はバックスラッシュと`n`の2文字である。コードポイント0x3042(`'あ'`)の`show`も、同様に複数文字の数値形式にエスケープされる。`stripQuotes`が両端から取り除くのは1文字ずつなので、こうしたコードポイントでは、結果が実際の文字ではなくエスケープ列の文字列(たとえばバックスラッシュと`n`)になってしまう。

`Compiler.RC2.ConstFold.constFoldOp`は、上流の`getOp`を改変せずにそのまま呼び出す(再実装はしていない)。したがって`Cast CharType StringType`を畳み込めば、このバグをそのまま引き継ぐ。手作業で確認したところ、`cast 'あ'`を`castString`で畳み込むと、誤ったエスケープ文字列になる。rc2自身のランタイム(`support/rc2/numeric.c`の`idris2rc2_cast_Char_to_string`。コードポイントをUTF-8のバイト列に変換するだけで、エスケープは一切しない)が返す正しいUTF-8とは異なる結果である。

`foldableOp`の`Cast from StringType`のケースは`isJust (intKind from)`でガードされており、`intKind CharType = Nothing`である。このため、`Char`の除外はすでに自動的に成り立っている。`Cast CharType StringType = False`のような専用の節を別に保守する必要はない。将来「簡素化」として、`Cast from StringType`を一般則`isJust (intKind from) && isJust (intKind to)`に統合したとしても、`Char`は(同じ理由で)正しく除外されたままである。したがって、本書が警告する本当の危険は別にある。上流の`stripQuotes`のバグが修正される(あるいは`castString`の`Ch`のケースが正しい実装に置き換わる)ときに、`foldableOp`を広げても安全になったかどうかを、rc2側が再検討しないまま残ることである。

テストは、`rc2/tests/Test17ConstFold.idr`の`castCharToStringNotFolded`である。このテストは`'あ'`をキャストする。普通の英字ではなく非ASCIIのコードポイントを選んだのは、除外が壊れて畳み込まれてしまった場合に、偶然一致することなく明らかに誤った文字列になるからである。テストでは、実行時の出力が正しいUTF-8であることを検査する。

## `Double -> String`: ホスト側の`Show Double`とrc2自身のフォーマッタ

`castString`の`Db`のケース(`Primitives.idr:41`)は`Str (show i)`である。これは*ホスト*のIdris2コンパイラ自身の`Show Double`が生成する文字列(通常はChezの`number->string`)をそのまま使う。rc2自身のランタイム(`support/rc2/numeric.c`の`idris2rc2_cast_Double_to_string`)は、現在は同じdoubleに往復できる最短の十進表現を出力する。以前の固定の`"%f"`よりはChezにずっと近いが、1文字単位で一致する保証はない。指数表記に切り替える閾値はrc2が独自に決めたもの(`(-6, 21]`は小数表記、それ以外は`<m>e<n>`)であり、`0.5`の先頭の`0`もrc2は残すのに対し、Chezは`.5`と書く。そのため、畳み込みを許せば、コンパイル時に得られる文字列が、実行時のキャストの結果と微妙に食い違うおそれがある。

ただし、この方向は別の層でも止まっている。`ConstFold.safeConst`は、`Cast`に限らず*すべての* PrimFnで`Db`を除外している(`I`を除外していたのと同じ理由で、ホストとの幅や丸めの食い違いが起こりうるため)。したがって`constFoldOp`の`all safeConst cs`の検査によって、`foldableOp`の判定に関係なく、`Cast DoubleType StringType`の畳み込みはすでに拒否される。さらに`foldableOp`の`Cast from StringType = isJust (intKind from)`も、独立した2つ目の遮断になっている(`intKind DoubleType = Nothing`)。どちらも意図したものである。片方が唯一の防壁になっている間は、もう片方を外してはならない。この方向を再検討する場合、確認すべき内容は以前より小さくなった。rc2の最短形式のフォーマッタが、境界値を一通り試したときに、ホストの出力と一致するか(指数表記や先頭のゼロの慣習を含む)を調べればよい。ただし出発点は、やはりプロジェクト全体にかかる`safeConst`の`Db`の除外である。

テストは、`Test17ConstFold.idr`の`castDoubleToStringNotFolded`である。

## `Double`の算術と`Int`/`Integer` -> `Double`: 畳み込んで安全だが、`safeConst`の一律の`Db`除外で止まっている

`safeConst (Db _) = False`は、大づかみなスイッチ1つで、`Db`のリテラルをオペランドに含むPrimFnを、**どれも** `constFoldOp`に畳み込ませない。上の2つの`Cast`の方向だけでなく、次のものがすべて対象になる。

- `Add` / `Sub` / `Mul` / `Div` / `Neg DoubleType`
- `Double`の比較
- `DoubleSqrt` / `DoubleFloor` / `DoubleCeiling`
- 超越関数(`DoubleExp` / `Log` / `Pow` / `Sin` / `Cos` / `Tan` / `ASin` / `ACos` / `ATan`)
- `Cast (固定幅整数 / Integer) -> DoubleType`

`getOp`はこれらをすべて実装している(`Primitives.idr:212-495`、`castDouble`は`:129-141`)。したがって、コンパイル時の畳み込みを妨げているのはこのガードだけである。`Cast _ -> Double`の形については、これに加えて`foldableOp`の`intKind DoubleType = Nothing`も妨げになっている。

このうち、算術演算と比較は実際に畳み込んで**安全**である。IEEE 754のbinary64の加減乗除、符号反転、順序比較は、ビット単位で厳密に決まる。ホスト側の評価器(`getOp`の`add (Db x) (Db y) = Db (x + y)`など。コンパイラをどのバックエンドでビルドしたかによらない)と、rc2のCランタイム(ハードウェアの`double`)で、結果は同一である。`DoubleSqrt`はIEEEが正しく丸めることを要求しており、`DoubleFloor`と`DoubleCeiling`は厳密な演算なので、この3つも安全である。`Cast (固定幅整数 / Integer) -> Double`はIEEEにより最近接偶数への丸めと決まっており、ホストとターゲットで一致する(非常に大きな`Integer`は2^53を超えると精度を失うが、双方とも同じように丸める)。

一律の除外を緩めたとしても、次のものは除外したままにしなければならない。

- `Cast DoubleType StringType`と`Cast StringType DoubleType`。前後の節に書いたフォーマッタとパーサの不一致が原因である。
- `Cast DoubleType -> (固定幅整数)`。範囲外やNaNのオペランドをゼロ方向に切り捨てる処理は、プラットフォーム依存である。`intKind DoubleType = Nothing`により、すべての整数の変換先でこの方向は遮断されている。
- 超越関数。`doubleOp exp`などは、(コンパイラをビルドしたバックエンド、たとえばChezの`flexp`経由で)*ホストの* libmを呼び出す。これがターゲットのCの`libm`と最後のULPまで一致する保証はない。

したがって、これを有効にするのは1行の変更では済まない。必要な作業は次のとおりである。

- `safeConst`(または`constFoldOp`側の補助的な検査)が、*どの* PrimFnを守っているのかを区別できるようにする。
- `foldableOp`に`Cast from DoubleType = isJust (intKind from)`の節を加える。`Char -> Double`を巻き込まないよう、`Cast from StringType`のケースと同じ書き方にする。
- `Inline.idr`の`allLiteralArgs`のオーバーフロー防止ガードは`safeConst`を再利用しており、これが引き続き動くようにする。このガードが対象にするのは、gccの`-Werror=overflow`のもとでの固定幅*整数*のラップアラウンドであり、`Double`の式の連鎖ではこれは起こらない。したがって、`hasUnfoldableConst`から`Db`を外しても問題ない。

2026-09-10に調査したが、まだ実施していない。この項目の元になった融合のコミットは、`git log`を参照のこと。

## `String`を`Cast`の変換元とする場合(どちら向きでも): パーサの意味論が未検証

`Core.Primitives.getOp`の`Cast`の振り分けは、いくつかの変換先について`String`を*変換元*としても受け付ける。`castInteger` / `castInt` / `castDouble` (`Primitives.idr:58,73,140`)には、いずれも`Str`のケースがあり、ホスト自身の`Prelude.Cast String X`インスタンス(`prim__cast_StringInteger`など、バックエンド定義のプリミティブ)で文字列をパースする。このパーサが、rc2自身のランタイムのパーサ(`support/rc2/numeric.c`の、`mpz_set_str` / `atoll` / `atof`ベースの`String -> Integer/Int*/Double`キャスト。不正な入力に対する明示的なエラー処理はどれも持たない)とバイト単位で一致するかどうかは、検証されていない。しかも、このエコシステムのパーサどうしが常に一致するわけではないという具体的な証拠がある。`rc2/tests/Test7CastMatrix.idr`の冒頭コメント(15-19行目)には、次のように書かれている。rc2の`String -> Int64/Bits64`のキャストは、RefCの`atoi`ベースの(したがって32ビットに制限される)実装を再現せず、あえて`atoll`でパースする。そしてテスト値は、この食い違いを突くのではなく、バックエンド間で比較できるように`atoi`の範囲内に収めている。C側の*ランタイム*実装の2つ(rc2とRefC)がすでに範囲について食い違っているのだから、ホストのIdris2コンパイラ自身の評価器(通常はChezでビルドされたもの)が、コンパイル時にそのどちらかと一致すると考える根拠はない。

もう1点ある。`getOp`の`castBits8` / `castInt8`など(固定幅整数が変換先の場合。`constantIntegerValue`経由、`Primitives.idr:76-87`)には、`Str`のケースが**まったく**ない。そのため`String -> Bits8`などは、`foldableOp`が何をするかとは無関係に、`getOp`の段階ですでに`Nothing`を返す。`getOp`の層で実際に畳み込まれうるため、明示的な除外が必要なのは`String -> Integer` / `Int`(サフィックスなし)/ `Double`だけである。このうち`String -> Int`と`String -> Double`は、一般則の`intKind StringType = Nothing`で除外される。`getOp`の層で畳み込まれうるのに、ほかの手段では除外されていないのは、`String -> Integer`だけである。現状では、`foldableOp`の一般則`Cast from to = isJust (intKind from) && isJust (intKind to)`が、これを正しく処理している(`intKind StringType = Nothing`のため)。ただし、`Char`の場合と同じ注意が当てはまる。これは`intKind`の現在の定義の副作用にすぎず、手作業で保守している安全検査ではない。`intKind`や一般則の形が変わったとき、この除外が維持されると思い込んではならない。

テストは、`Test17ConstFold.idr`の`castStringToIntegerNotFolded`である。

## ファイル

- `rc2/src/Compiler/RC2/ConstFold.idr` -- `foldableOp`のドキュメントコメントに、この議論の要約がある。本書はその詳細版である。
- `idris2-src/src/Core/Primitives.idr` -- `castString` / `castTo` / `castInt` / `castInteger` / `castDouble`。31-160行目付近と550-613行目。
- `idris2-src/libs/prelude/Prelude/Show.idr` -- `Show Char`の複数文字エスケープ(`showLitChar`)。
- `idris2-src/src/Libraries/Utils/String.idr` -- `stripQuotes`。
- `rc2/support/rc2/numeric.c` -- rc2自身のランタイムのCast実装(`idris2rc2_cast_Char_to_string`、最短形式の`Double -> String`フォーマッタ、GMPで厳密な`String -> Double`パーサ、`String -> Integer/Int*`のパーサ)。
- `rc2/tests/Test7CastMatrix.idr` -- 冒頭コメントに、`atoll`と`atoi`によるStringを変換元とするキャストの食い違いが書かれている。また、この周辺を調べる中で見つかった、上流のRefCランタイムの無関係なバグ3件も書かれている。`idris2_cast_Double_to_Int8`が存在しない、`idris2_cast_String_to_*`が大文字のSで定義されているのにRefCのコンパイラ自身は小文字の形を呼び出すコードを出力する、`idris2_negate_Double`が`idris2_nagate_Double`と誤記されている、の3件である。いずれもrc2のバグではない。
- `rc2/tests/Test17ConstFold.idr` -- 上記3方向が畳み込まれないままであることを確認する回帰テスト。
- `rc2/src/Compiler/RC2/InlineCExp.idr` -- `allLiteralArgs` / `hasUnfoldableConst`は`safeConst`を再利用している。`Db`の扱いをここで変えるときは、gccの`-Werror=overflow`のガードが引き続き動くようにすること。

## 検証手順(この問題を再び検討する場合)

1. **`Char -> String`**: まず、上流の`castString`の`Ch`のケース(または`stripQuotes`)が、複数文字のエスケープを正しく扱えるよう修正されたかどうかを確認する。修正されていた場合も、`foldableOp`を広げるだけで済ませてはならない。修正の考え方を取り込み、`Show Char`の現在のエスケープ規則から、ASCIIの印字可能文字だけでなくすべてのコードポイントが、`show`とエスケープ解除を通して正しく往復できるかを、あらためて導出する。
2. **`Double -> String`**: プロジェクト全体にかかる`safeConst`の`Db`の除外を先に見直さない限り、先へ進めない。この除外は`Cast`だけでなくすべてのPrimFnから`Db`を除外しており、見直しは別の大きな判断になる。その範囲は、上の「`Double`の算術と ...」の節に整理してある。着手する場合は、1つの例を信用する前に、境界値を一通り試して、`idris2rc2_cast_Double_to_string`の最短形式の出力を、ホスト自身の`Show Double`の出力と照合する。試す値は、0.0、負のゼロ、非常に大きい値と小さい値、小数表記と指数表記の閾値の両側、先頭のゼロの慣習が異なる`|x| < 1`である。算術・比較・`Sqrt`・`Floor`・`Ceiling`・`int -> Double`の部分集合には、こうした検証は要らない(どちら側でもIEEEで厳密に決まる)。超越関数には必要である(ホストの`libm`とターゲットの`libm`の違い)。
3. **`String -> Integer`**: rc2の`mpz_set_str`ベースの実行時パースと、同じリテラルに対するコンパイル時の`getOp`による畳み込みの両方を試す再現コードを書く。入力は整形式の十進整数だけでなく、不正な入力や端のケース(先頭の`+`、空白、先頭のゼロ、空文字列、オーバーフロー)も含める。両者が一致することを確認して初めて、`intKind`の定義が変わった場合でも`intKind`ベースの一般的な除外が維持されると信頼できる。
4. 再現コードに`--directive dumprcexpr`(`rc2/doc/reading-the-ir.md`を参照)を使うと、ある`Cast`が畳み込まれたのか(`RPrimVal`)、実行時の`op cast-...`のまま残ったのかが分かる。生成されたCを読まずに`foldableOp`の実際の挙動を確かめる、最も速い方法である。

## `Int`は`Int64`と同様に畳み込む(2026-09-26)

上流の`foldableOp`は`Cast IntType _`と`Cast _ IntType`を拒否しており、rc2の`safeConst`も、以前は`I`のオペランドをすべて拒否していた。`Int`の幅がバックエンド依存だからである。rc2では、そうではない。`Int`はCの`int64_t`であり、`Int64`とまったく同じように出力される(`nativeCType`、`isSigned`、`intBits`、`idris2rc2_ediv_i64` / `emod_i64`の組)。`getOp`も`I`と`I64`を同じように評価する(64ビットのラップアラウンド、ユークリッド除算の`div` / `mod`、キャスト時は`Integer`の下位64ビット)。このため2つの除外はどちらも取り除き、`Int`は従来から`Int64`が畳み込まれていたのと同じ方法で畳み込まれるようになった。上の各節で除外した方向は、すべて`intKind`だけで除外されたままである。

しかし、それだけでは最もよくあるケースに届かなかった。`Int`のリテラルは`fromInteger n`、つまり`Integer`リテラルに対する`cast-Integer-Int`である。そして100以上のリテラルは、`RC.idr`の`bindOne`により`RCConst`にならずlet束縛される。そのため、このキャストには読み取れる定数がなかった。ConstFoldは現在、そのようなリテラルを`Env.bigLits`に保持する。`let`は所有権のために残る(`const-con-fold.md`のBug #2)が、それを読む演算は畳み込まれ、何も読まなくなった時点で`let`は消える。`Test91IntConstFold`は、畳み込まれた各値を、同じ計算を実行時に行った結果と照合する。

ループの中の`Int`の`i + 1000`は、以前は反復のたびに`Integer`の`1000`を作ってキャストしていた。`tests/BenchStructReturnNative.idr`は、864 ms・割り当て20M回から54 ms・35回になった。idris2-missing-containersの実行時間は10.36 sから9.69 sになった(6.5% 高速化。生成されたCが作る`Integer`リテラルは12個から4個に減った)。idris2-lspの最終IRにある`cast-Integer-Int`の演算は、416個から211個になった。
