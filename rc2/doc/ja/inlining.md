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
`--directive noinline`はこれをスキップする。`noloop`/`noconaltnative`
などが既に提供しているのと同じ種類のA/Bリグレッション切り分けのため
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

## 基準B、再訪: `Compiler.RC2.LateInline`

このドキュメントの「適格性」節で「検討したが見送った」としていた
「プログラム全体で単一呼び出し元」という基準は、後のセッションで
別パスとして改めて実装された -- `Compiler.RC2.LateInline`。`Lifted`
ではなく`RCExp`を対象に、上記の`Compiler.RC2.Inline`よりずっと
パイプラインの後段で走る。`--directive nolateinline`で無効化できる。

### 動機

`Compiler.RC2.SpecClosure`はクロージャ引数を取る関数について、
呼び出し箇所ごとに特殊化されたクローンを作る
(`rc2/doc/speculative-closure-specialization.md`参照) -- 元の関数が
自己再帰していた場合、SpecClosureが生成した時点のクローンも
自己再帰している。この自己再帰こそが、基準Aの「呼び出しを含まない
こと」という要件(このドキュメントの「適格性」節)がこうしたクローンを
そのまま門前払いしていた理由である: 呼び出しを(自分自身へのもので
あっても)含むcalleeはcall-freeではない。

`Compiler.RC2.Loop`(および`MutualLoop`)は、通常の自己(および相互
末尾)再帰を`RLoop`/`RLoopContinue`へと既に畳み込んでいる --
元の名前への呼び出しが一切残らない、goto方式のループである。
Loop変換*前*には再帰的に見えていた呼び出しグラフも、変換*後*には
完全に普通の、非再帰的な、他のどんな関数とも同じようにインライン化
可能なものに見える。SpecClosureのクローンは構成上必ず1箇所の呼び出し
のために作られるので、Loop変換さえ終われば無条件に単一呼び出し元
適格でもある -- 以前の調査では見つからなかった、基準B自身の単一
呼び出し元基準にとって初めての、具体的で有意義な動機となるケースが
ようやく揃ったことになる。

### パイプライン上の位置

```
  -> Compiler.RC2.MutualLoop      (相互末尾再帰 -> 1個のマージ済み関数)
  -> Compiler.RC2.Loop            (自己末尾再帰 -> RLoop/RLoopContinue、
                                    ネイティブshadow昇格も)
  -> Compiler.RC2.LateInline      (このパス -- プログラム全体のインライン化、RCExp -> RCExp)
  -> Compiler.RC2.Sink            (分岐ローカルなlet値の押し込み)
  -> Compiler.RC2.DualABI         (worker/wrapper合成、呼び出し箇所書き換え)
  -> Compiler.RC2.DeadCode        (プログラム全体の到達可能性による刈り込み)
  -> Compiler.RC2.DupMerge
  -> Compiler.RC2.Emit            (純粋に機械的なRCExp -> C)
```

Loop/MutualLoop変換の後に厳密に置く -- これより前に走らせると、
このパスが本来届くべきクローンをまさに拒絶してしまう理由は上記
「動機」参照。Sinkより厳密に前に置くのは、このパスがちょうど
差し込んだ値(例えば丸ごと1個のループが、あるブランチの`RLet`の値と
して生きている場合)がSink自身のブランチローカルな配置判断の対象に
まだなれるようにするため。DualABIより厳密に前に置く -- その選択の
実際に見つかった結果については下記「既知の制限: DualABI自身の
ネイティブ適格性解析」参照、なぜそれでも変えなかったかも含めて。

インライン化済みの元の定義は、ここでは明示的には削除しない
-- 既にパイプラインの後段に置かれている`Compiler.RC2.DeadCode`が、
他のあらゆる到達不能な定義と同様、誰からも参照されなくなった時点で
自分で刈り取る -- ただし*他の*何か(例えば`RUnderApp`/
`RCConstClosure`として保持されるクロージャ値であって、直接呼び出しで
はない)がまだそれを参照していれば、正しく生き残る。このパスは
「唯一だと証明できる呼び出し箇所」だけを取り除き、定義自体を消す
ことは無い。

### 適格性 -- そしてそれがそのまま損益ゲートになる理由

以下を全て満たすとき、その呼び出し箇所でcalleeがインライン化される
(プログラム全体基準):

- `RAppName`の出現が全体で*ちょうど1回*(`analyse`自身の
  `callCounts`。`RCExp.idr`の汎用`foldRCNamesD`/`RCNameFold`機構経由で
  構築され、専用の走査コードは書いていない);
- 本物の`MkRCFun`である(`RCCon`/`RCForeign`/`RCError`ではない); そして
- プログラム全体の`RAppName`呼び出しグラフ上のどの閉路にも属さない
  -- サイズ2以上のTarjan SCC、または直接の自己辺(後者は、この時点で
  まだ直接自己再帰している関数、例えば`Compiler.RC2.Loop`が一切
  触らない非*末尾*自己呼び出しを捕まえる -- こういうものをインライン
  化すると際限なく複製されてしまう)。

基準Aと違い、別立てのサイズ上限は無い。単一呼び出し元のインライン化
は無条件に「損益的に安全」だと扱ってよい: callee側の呼び出し箇所が
ちょうど1個しか無いので、そこへ差し込んでもプログラム中のそのコード
の複製数が増えることは絶対に無い -- 最悪でもサイズ中立(呼び出し自体
のオーバーヘッドが消える分、実際には常に純増の得になる)。サイズ上限
が意味を持つのは、適格性が「小さければ複数呼び出し元でも可」
(基準A自身の形)にまで広げられた場合だけであり、今回はそこまで
手を出していない -- 下記「既知の制限」参照。

処理は`tarjanSCCs`自身の逆順、callee-before-caller順(`defs`自身の
たまたまの並び順ではなく、`Compiler.RC2.MutualLoop`からそのまま
再利用した同じ`Graph`/`tarjanSCCs` -- まさにこの再利用のために
そちらで`public export`にされていた)で走る -- なので`C`の唯一の
呼び出し元が`B`、`B`の唯一の呼び出し元が`A`だとすると、`B`への`C`の
インライン化を`A`への`B`の処理より*先に*終えておけば、`A`は
「`C`が既にインライン化済みの`B`」を一度のパスでまるごと受け取れる
-- 連鎖全体の畳み込みに再実行は要らない。

### すべてのidを差し込み時にリネームする -- callee自身の内部idも含めて

差し込みでは、呼び出しの「トップレベル引数からパラメータへ」の
束縛を引数ごとの`RLet`に置き換え、callee自身のパラメータidへの
あらゆる出現を、差し込まれた本体全体にわたってその新しい`RLet`
自身のidへリネームする(`Compiler.RC2.Loop`自身の`Renaming`/
`renameRCExp`をそのまま再利用)。この中で見た目ほど自明でない点が
2つあり、どちらも実装中に実際のバグとして見つかった:

1. **引数は、呼び出し元で既に裸の`RCLoc`であっても、必ず新しい
   idを得る。** 「実引数が既に`RCLoc j`なら`RLet`を挟まずパラメータ
   idを直接`j`へリネームすればよい」という近道は魅力的に見えるが、
   通常の(インライン化しない)呼び出しがただで与えてくれる独立性を
   壊してしまう。Loop変換済みのcalleeが持つ`RLoop`は、自分自身の
   トップレベルパラメータのidを*可変*なループ持ち回し変数として
   よく再利用する(`Compiler.RC2.Loop`自身の「自分のidを再利用する」
   ケース、`Emit.idr`自身の`declareLoopParam`)。そのidを呼び出し元の
   `j`へ直接エイリアスすると、差し込まれたループが呼び出し元自身の
   変数をその場で書き換えてしまう。**発見の経緯**: `map (*2) xs`の
   直後に同じ`xs`への`filter p xs`が続き、両方とも単一呼び出し元
   適格で同じ呼び出し元へ続けて差し込まれた -- 両方とも同じidへ
   リネームされていたため、`filter`自身のループが読む前に`map`自身の
   ループが共有変数`xs`を`NIL`まで書き潰してしまった。
   `printLn (filter p xs)`は正しい結果ではなく`[]`を出力した。
2. **callee自身の*内部*idも、トップレベルパラメータだけでなく
   リネームが必要** -- `Compiler.RC2.Util`自身の`VarId`カウンタが
   既にあらゆるidを最初に割り当てられた瞬間からプログラム全体で
   一意にしているにもかかわらず、である(そのモジュール自身のdoc
   コメント参照)。例外は`Compiler.RC2.SpecClosure`: 1個の共有された
   元の本体から*複数の*クローンを作り、各クローン自身のapply連鎖/
   自己呼び出しだけを書き換え、本体の残り -- 内部id込み -- はそのまま
   複製して全クローンへコピーする。そのため2個のクローンが自分自身の
   内部idを正当に共有していることがあり得るが、それぞれが別々のC
   関数のままである限りは無害(Cはローカル変数を関数ごとにスコープ
   するので、無関係な2つの関数がそれぞれ自分の`var_301`を持っていても
   衝突しない)。同じ呼び出し元へ2個のそういうクローンを差し込むと、
   その分離が崩れる。**発見の経緯**: 同じ元の`String -> ... -> Boxed`
   ヘルパーのSpecClosureクローンが2個(それぞれ単一呼び出し元)、
   共有元から丸ごと受け継いだ無関係な`let v301 = call
   Data.String.Iterator.fromString [...]`をそれぞれ持っていて --
   両方が同じ呼び出し元へ差し込まれた結果、1個の関数の中に`var_301`
   のC宣言が2つできてしまった(`error: redefinition of 'var_301'`)。

`collectBoundIds`(このモジュール自身のコピー -- `RLet`自身の`var`、
`RConAlt`自身の分解された`args`、`RLoop`自身の`loopParams`。同じ
ノード形を、このセッションの`VarId`統一で不要になる前は
`Compiler.RC2.Loop`と`Compiler.RC2.MutualLoop`もそれぞれ自前のコピー
でカバーしていた)がcallee自身の内部idを全て見つけ、それぞれ
`Compiler.RC2.Util`の`freshVarId`で新しいidを得て、パラメータの
置換と同じ`Renaming`へまとめられる。

### 1関数内の複数ループ

既に自分自身の`RLoop`(自己再帰済みのもの、このパスが走るより前に
変換済み)を持つ呼び出し元へ、*別の*、独立してLoop変換済みのcallee
をインライン化すると、`rc2/doc/loop-conversion.md`の「1関数内の
複数ループ」節が`Emit.idr`に正しく扱わせるようにしたまさにその
「1関数に2個以上のRLoop」という形になる -- ここで特別扱いは不要:
`emitInto`は既に`RLoop`を任意の`sink`/`TailPositionStatus`について
汎用的にディスパッチするので、ループ持ちのcalleeが普通の`RLet`の
値として差し込まれれば(このパス自身の既定の形、上記「すべてのid
を差し込み時にリネームする」参照)、並列でもネストでも既に正しく
下ろせる。

### 修正済み: DualABI自身のネイティブ適格性解析にあった「ループは1個」前提

`Compiler.RC2.DualABI`の`findLoopThroughLets`/`paramEligibility`
(パラメータのネイティブ昇格を判断する箇所)は「1関数につき`RLoop`は
高々1個」という、このパスが存在するまではどこでも真だった前提の下で
書かれていた -- `findLoopThroughLets`(純粋な`RLet`の連なりの先に
到達可能な*最初の*`RLoop`しか見つけず、その本体の中にさらにネストした
ループが無いか探すことなくそこで止まっていた)も、`Loop.idr`自身の
`nativeArgTypesFor`/`nativeArgTypes`(そういう連なりの先にループが
全く無い場合 -- 例えば本体の根とループの間に`case`が挟まる場合、
このパスがループ変換済みcalleeを根以外のどこにでも差し込めるように
なった今ではよくある形 -- に`paramEligibility`が使うフォールバック)
にも`RLoop`のケース自体が無く、その本体へ一切再帰しなかった。

このパスが、既に自分自身のループを持っているかもしれない呼び出し元
へLoop変換済みのcalleeを、ネストさせる形であれ`case`の先であれ
差し込めるようになった今(上記「1関数内の複数ループ」参照)、
インライン化されたループの*内部*だけでネイティブに使われている
トップレベルパラメータは、`paramEligibility`のどちらの経路からも
見えなくなり、ネイティブworker引数へ昇格されることが無かった --
`DualABI.idr`/`Loop.idr`を直接読んで追跡し、仮説ではなく実際に
確認済み。

**修正**: `nativeArgTypesFor`/`nativeArgTypes`(`Loop.idr`)は、他の
あらゆるラッパーノードと同様に`RLoop`自身の`body`へ再帰するように
した(`loopParams`/`initial`/`prologueDrop`はスキャンすべき演算では
なくメタデータなので無視する) -- これだけで差し込み後によくある形の
穴は閉じる。`findLoopThroughLets`が(純粋な`RLet`の連なりの先にループ、
という形以外の何であれ)`Nothing`を返す場合は、既にこのフォールバック
へ回っていたため。`findLoopThroughLets`(`DualABI.idr`)側も、見つけた
ループ自身の`body`へ再帰して*さらに*ネストした本物のループを探し、
各段の`loopParams`を全て合算するようにした -- `paramEligibility`が
それでも`Just`分岐を取るケースをカバーする。本物の*兄弟*ループ
(ネストではなく、最初のループの後に別の経路で到達するもの)は、
この修正後も依然としてこの経路では見つけられない -- `RLoop`自身には
「そしてその後」を続けるためのフィールドが無いため -- が、その形は
そもそも`findLoopThroughLets`自身の`Just`分岐を一度も通らず、
既に(今回直した)フォールバックへ回っていた。フルの回帰スイート
(85/0、16/16)で再検証済み -- golden出力の再生成は不要だった、
つまりスイート中には今回閉じた穴を実際に踏むものは無かったという
ことであり、この修正は`Compiler.RC2.LateInline`が新たに到達可能に
した形を狙ったものである。

### ファイル

- `rc2/src/Compiler/RC2/LateInline.idr` -- このパスそのもの、全体。
- `rc2/src/Compiler/RC2/Loop.idr` -- `Renaming`/`renameRCExp`。id置換の
  ためにそのまま再利用。
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `Graph`/`tarjanSCCs`。閉路
  除外とcallee-before-caller順のためにそのまま再利用。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身の配線(Loop変換と
  Sinkの間)、`"nolateinline"`ディレクティブ。

### 検証方法

1. フルビルド+テストスイート: `rc2/tests/verify.sh`(85/0)と
   `libs/rc2base/tests/verify.sh`(16/16)、どちらも`valgrind`込み。
2. 手書きrepro: `go`/`mkTarget`型の自己再帰する高階関数を、
   SpecClosureが2箇所の呼び出しでそれぞれ特殊化 -- `--directive
   dumprcexpr`で、両クローンが(独立したトップレベル定義としてはもう
   存在せず)`main`へ直接差し込まれ、それぞれ独自の`RLoop`/生成C上の
   `loop_N:`ラベルを持ち、出力は変わらず正しいことを確認。
3. `rc2/tests/refc-suite/callingConvention`自身のgolden出力は、この
   セッションの他の変更が引き起こした通常の`var_N`/`tmp_N`の
   再採番による差分*とは別の*理由で再生成が必要だった:
   このパスが`sumLoop`/`eligibleAdd`/`tailAbs`を、`Compiler.RC2.DualABI`
   がそれらのworkerを合成する前にインライン化して消してしまうため、
   それらのworker関数は別個のC関数としては存在しなくなる。再生成を
   受け入れる前に、プログラム自身のstdoutが変わっていないことを
   (テスト自身のCソース構造アサーションとは別に、バイナリを直接
   実行して)確認済み -- インライン化はDualABI自身の最適化がコストを
   削っていた呼び出し境界そのものを取り除くので、これらの特定の
   関数についてその狭い最適化がもう要らなくなるのは想定通りであり、
   後退ではない。

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
