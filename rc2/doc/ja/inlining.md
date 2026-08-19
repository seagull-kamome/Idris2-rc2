# `Compiler.RC2.Inline`: プログラム全体の`Lifted`から`Lifted`へのインライン化

(原文: `doc/inlining.md`。内容が乖離した場合は原文を正とする。)

## 動機

`Compiler.RC2.RC`の`tryFuseCompare`は、二分岐のBoolマッチに直接消費
される*直接の*プリミティブ比較を、単一のネイティブ`RCmpCase`へ融合
する -- boxedな`Bool`は一切実体化されず、分岐は自身のオペランドを
ネイティブに読む。しかしこれは、比較がそのマッチのすぐ隣に座る裸の
`LOp`/`ROp`である場合にのみ発火する: 比較が代わりにインターフェース
メソッド呼び出し経由で到達する場合(例えば`Ord Int`の`<=`経由の
`acc <= 0` -- これは本物の、静的に解決されるトップレベル関数であり、
辞書パラメータ化されたものではない -- 固定幅スカラー型だけがそもそも
ネイティブ適格になりうる)、融合はそれ自体では一切発火しない。比較は
`<=`自身の別個の定義の内側に座っており、呼び出し元自身の融合解析
からは不可視である。

`Compiler.RC2.Inline`は、`Compiler.RC2.RC`自身のPhase 1(`normalize`)
がプログラムを目にするよりも前に一度だけ実行され、小さく、呼び出し
を含まない呼び出し先自身の本体を呼び出しサイトへ直接継ぎ足すこと
で、この隙間を閉じる -- そのため`RC.idr`の視点からは、その呼び出しは
そもそも存在しなかったことになる。動機となった正確な形と、それを
`--directive dumprcexpr`/`--directive noinline`経由でどう確認するかは
`rc2/tests/Test15CompareFusionThroughCall.idr`参照。

## パイプライン上の位置

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (このモジュール -- プログラム全体のインライン化、Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF風正規化、ネイティブ型推論)
  -> Compiler.RC2.RC.annotate     (Phase 2: 所有権 -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (コンストラクタのin-place再利用)
  -> Compiler.RC2.ConAltNative    (ネイティブshadowフィールドキャッシュ)
  -> Compiler.RC2.MutualLoop      (相互末尾再帰 -> 1つの合成関数へ)
  -> Compiler.RC2.Loop            (自己末尾呼び出し -> RLoop/RLoopContinue、
                                    かつネイティブshadow昇格)
  -> Compiler.RC2.DualABI         (worker/wrapper合成、呼び出しサイト書き換え)
  -> Compiler.RC2.Emit            (RCExp -> C、純粋に機械的な変換)
```

RC2固有のものが何も存在しない時点で、最初に実行される --
`Compiler.RC2.RC2`自身の`toRCDefs`は、他のどのステージよりも前に、
生の`lambdaLifted`リストに対して`applyInlineLifted`を呼び出す。
`--directive noinline`はこれをスキップする。`noreuse`/`noloop`など
が既に提供しているのと同じ種類のA/Bリグレッション切り分けのため
(`RC2.idr`自身の`toRCDefs`に関するモジュール注記参照)。

## 適格性: 基準Aのみ

呼び出し先は、以下の全てを満たす場合、自身の*全ての*呼び出しサイト
でインライン化される:

- 本物のトップレベル定義である(`MkLFun args scope body`で
  `scope = []` -- ラムダリフトされて切り出されたクロージャヘルパー
  は、自身の捕捉された自由変数からなる`scope`が常に非空であるため、
  決して適格にならない: インライン化には*閉じた*本体、つまり自身の
  `args`のみを参照する本体が必要である);
- 自身の本体が*呼び出しを含まない*(`isCallFree`: どこにも
  `LAppName`/`LUnderApp`/`LApp`/`LExtPrim`が無い); かつ
- 自身の本体が小さい(`sizeOf body <= smallBodyThreshold`、現在は
  24 -- 大まかな構造ノード数であって、実際の生成Cサイズに対して
  較正されたものではない)。

これは意図的に、一般的な「小さい関数をインライン化する」パスより
狭い。呼び出しを含まないという要件は、適格な呼び出し先自身が決して
さらなるインライン化対象の呼び出しを含みえないことを意味する --
そのため`inlineLifted`自身のプログラム全体書き換えは1パスだけで
済み、不動点を必要とすることは決してない: 呼び出しを含まない本体を
継ぎ足すことは、たった今継ぎ足したものの内側に*新しい*インライン化
の機会を生み出すことはできない(生まれうるのは呼び出し自身の*引数*
の内側だけであり、それは呼び出し自身が検討される前にボトムアップで
処理される)。

第二の基準(呼び出しサイトが単一、プログラム全体規模、
`Compiler.RC2.MutualLoop`自身の`Graph`/`tarjanSCCs`を再利用した
Tarjan-SCC呼び出しグラフ経由で順序付け)は、以前のセッションで基準A
と並んで調査されたが、別途文書化されているモナド的bind再利用の隙間
(`rc2/doc/reuse-monadic-bind-gap.md`)には*届かない*ことが確認され、
現時点で既知の他のいかなる隙間にとっても土台にはならなかった。この
パス自身の影響範囲を、実際に解決する問題に見合った大きさに保つため、
ここでは実装していない。`Graph`/`tarjanSCCs`は、将来のセッションが
これを見直す場合に備えて`MutualLoop.idr`で`public export`/`export`
にはしてある。

## `allLiteralArgs`ガード

引数が*全て*裸の`LPrimVal`リテラルである呼び出しは、他の条件を満た
していても決してインライン化されない。`Test6NativeInts.idr`自身の
`chainInt8 100 100`形の呼び出し経由で必要だと判明した: 固定幅算術の
連鎖が、全てのオペランドがコンパイル時定数の状態で継ぎ足されると、
gcc自身の`-Werror=overflow`が、意図的な2の補数のラップアラウンドを
静的に「オーバーフロー」だと証明してしまい、正しい、意図的なテスト
をコンパイルエラーに変えてしまう。0引数の呼び出しに対しては空虚に
真(「全てリテラル」であるべき引数が無い)なので、このガードは実際
には引数が少なくとも1つある場合にのみ発火する -- 0引数の呼び出しは
そもそもこの畳み込みリスクを持たない。

## IR配線: `Lifted`向けの`Weaken`/`Substitutable`

呼び出し先の本体を呼び出しサイトへ継ぎ足すことは、捕捉回避型の代入
である: 呼び出し先の引数の全ての出現を対応する呼び出し元側の式へ
置き換え、その過程で全てのローカル変数参照を正しく再インデックス
する。`Lifted`自身の`LLocal`は、`Core.TT.Term`自身の`Local`と全く
同じ`IsVar`ベースのde Bruijn表現を使っているので、このモジュールは
`Core.TT.Term`自身の`insertNames`/`GenWeaken`/`FreelyEmbeddable`
インスタンスと`Core.TT.Term.Subst`自身の`substTerm`を、構造そのまま
の形で`Lifted`/`LiftedConAlt`/`LiftedConstAlt`へ移植している --
`Lifted`固有またはrc2固有の捕捉回避機構は一切不要であり、汎用の
`Core.TT.Var`/`Core.TT.Subst`コンビネータ(`insertNVarNames`、
`find`)が実際のインデックス計算を全て行う。

`Term`自身のインスタンスが一度も必要としなかった点が2つある。
`Term`自身の`Bind`は常に一度に1つの名前しか導入しないためである:

- **`LiftedConAlt`の複数名バインダ。** コンストラクタの枝は、1つ
  だけでなく名前の*リスト*丸ごと(`args`)を一度に束縛する
  (`Lifted (args ++ vars)`) -- `insertNamesConAlt`/`substConAlt`は、
  型を揃えるために追加で1回`appendAssociative`の並べ替えが必要
  であり、これは本家の`Compiler.CaseOpts`自身の`shiftBinderConAlt`
  (`CConAlt`について既に同一の形を解決している)から移植した。
- **消去。** `Lifted`自身の`vars`スコープインデックスは、既に消去
  された`IsVar`証明(`LLocal`自身の`(0 p : IsVar x idx vars)`)の
  内側を除いては、*どの*コンストラクタからもランタイムで一切使われ
  ない -- Idris2自身の強制引数検出が、これを全域にわたって自動的に
  消去する。このモジュールが追加する、名前でスコープリストの
  implicitに言及するヘルパー(`insertNamesConAlt`、`substConAlt`、
  `toSubst`、`inlineCall`)は全て、それに合わせて明示的に`0`を
  マークしなければならず、そうしないとコンパイラは「`<name>`
  はこの文脈でアクセスできない」として呼び出しを拒否する --
  `Lifted`自身の消去されたインデックスは、消去されていないパラメータ
  が必要とするようなランタイム情報を単に持ち運ばない。これはまた、
  *なぜ*`FreelyEmbeddable Lifted`自身の`embed`(右側への追加、
  閉じた呼び出し先本体を代入する前に呼び出し元自身のスコープへ
  広げるために使われる)が単に`believe_me`で済むのかの理由でもある:
  どちらの側でもインデックスにランタイム情報がゼロなので、安全で
  ないキャストが間違えうるものが何も無い。
- **`Subst`自身のスパインからの`SizeOf`、`mkSizeOf`ではなく。**
  `inlineCall`は代入の種として`SizeOf calleeArgs`を必要とするが、
  `calleeArgs`はその文脈では消去されているので、`mkSizeOf
  calleeArgs`(実際のリストの長さを本当に数える)は使えない。
  `env`自身の`Subst`値は既にその長さを、消去されていない本物のcons
  スパイン構造としてエンコードしているので、`sizeOfSubst`は代わりに
  そこから読み取る。

## Case-of-caseの畳み込み

呼び出し自身のスクルティニー形の引数を`case`の位置へ代入すると、
「caseのcase」(`case (case x of ...) of ...`)が生じる -- これは
`tryFuseCompare`単体では認識しない。`collapseCaseOfCase`は本家の
`Compiler.CaseOpts`自身の`doCaseOfCase`/`doCaseOfConstCase`/
`tryCaseOfCase`(`CExp`レベルのcase-of-case半分のみ -- `Lifted`には
`LLam`が全く存在しない。ラムダリフティングが既に全てのラムダを消去
しているためであり、本家自身の「ラムダを持ち上げる」半分である
`caseLam`はここでは対応物を持たない)を`Lifted`へ移植し、インライン
化の後、木全体にわたってボトムアップで適用する。大きな外側のcaseを
全ての内側の枝に複製してしまうリスクを抑えるため、畳み込みは、内側
のcase自身の枝が全てコンストラクタ先頭である(あるいは枝がちょうど
1つでデフォルトが無い)場合にのみ発火する -- 本家自身の
`canCaseOfCase`と同一の制限である。

## 発見・修正したバグ

このセッションでのこのパスへの最初の試みは、フルの回帰スイートが
`Test9SelfTailLoop`自身の`collatzLike`における、インライン化が
初めて比較融合を自己末尾ループ自身のアキュムレータへ届かせた際に
発生する、本物の、`valgrind`で確認済みのリークを表面化させたことで、
完全に取り消された。Case-of-case畳み込みを絞り込む2回の試み(範囲を
限定し、その後完全に無効化)を経てもリークはバイト単位で不変であり、
根本原因を診断できないまま試みは棚上げされた(この調査の全貌は
`TODO.md`自身のgit履歴参照)。

*次の*セッションで、インライン化対象の関数呼び出しが1つも無い手
書きのソースプログラムでリークを再現することで見つかった実際の
根本原因は、`Compiler.RC2.Loop`/`Emit`における2つの完全に独立した、
既存のバグ(`RLoopContinue`の`postDrop`フィールドの欠落と、
`Emit.idr`自身の`ROp`ケースにおける未解放の一時的なbox)だった
ことが判明し、どちらもこのパス自体にあるものではなかった -- 両方の
完全な記述は`rc2/doc/loop-conversion.md`の「発見・修正したバグ」#5
参照。

どちらもこのパスとは独立に修正されており、どちらの修正も
`Inline.idr`には一切触れていない。このパス自身のロジック(IR配線、
case-of-caseの畳み込み、両方の適格性基準)は、元のリークが発見され
た時点で既に正しかった。動機となった比較融合のケースに対して、
その時点と、この再実装の後の両方で`--directive dumprcexpr`により
確認済み。

*この*実装の試みに固有の、別の、より狭いバグ: `--directive
noinline`の配線が、元のデバッグセッションの途中で密かに壊れていた
(`toRCDefs`が無条件に`applyInlineLifted`を呼んでおり、
`compileExpr`自身の認識されるディレクティブ一覧に`"noinline"`が
欠けていた)。これは誤った中間結論(「このリークは既存のもので、
このパスとは無関係」)を生み出した。なぜなら比較していた両方の
ビルドが密かにインライン化を有効にしたままだったからである。今回は
`--directive noinline`の有無で生成されたCをdiffすることで再検証して
から、それに基づくA/B比較を再び信頼するようにした
(`rc2/tests/Test14SmallFunctionInline.idr`と
`Test15CompareFusionThroughCall.idr`自身のドキュメントコメント参照。
どちらも2つのビルドの間で何が変わるはずかを正確に記述している)。

## ファイル

- `rc2/src/Compiler/RC2/Inline.idr` -- このパスそのもの、全体。
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `Graph`/`tarjanSCCs`。
  ここでの再利用のために`public export`/`export`にされている
  (基準B、現時点では未実装 -- 上記参照)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身の配線、
  `compileExpr`自身の`"noinline"`ディレクティブ。
- `rc2/tests/Test14SmallFunctionInline.idr`、
  `rc2/tests/Test15CompareFusionThroughCall.idr` -- それぞれ基準A、
  および動機となった比較融合のケース専用の回帰テスト。

## 検証方法

1. フルビルド+テストスイート: `CLAUDE.md`の「Build & test」節参照
   (コンパイラ、ランタイム、続けて`rc2/tests/verify.sh` -- 19/19の
   refc-suite、全てのスモークテスト、長らく記録されている既存の
   `Test1Basics`のリーク1件を除く全ての`LEAK_SENSITIVE_TESTS`エントリ
   で`valgrind`がクリーン)。
2. `Test15CompareFusionThroughCall.idr`に対する`--directive
   dumprcexpf`と`--directive dumprcexpf --directive noinline`の比較:
   インターフェース呼び出しが消え、単一のネイティブ`cmp <=Int
   [...]`に置き換わること、そしてその直接の結果として`step`自身の
   workerパラメータが`Boxed`から`Native Int`へ変わることを確認する。
3. `rc2/tests/bench.sh`: 既存のマイクロベンチマークスイートに
   タイミングの後退がないこと。
