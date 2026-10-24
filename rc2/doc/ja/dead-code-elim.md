# `Compiler.RC2.DeadCode`: プログラム全体のデッドコード除去

(原文: `doc/dead-code-elim.md`。内容が乖離した場合は原文を正とする。)

## 動機

`Compiler.Common.getCompileData`は、rc2が最初に受け取る`List (Name, LiftedDef)`を1回だけ計算する。上流Idris2自身の到達可能性解析を、*元の*呼び出しグラフ(`mainExpr`から到達できる範囲に、`%export`された名前を加えたもの)に対して適用するものである。続いて`Compiler.RC2.RC2`の`toRCDefs`が、rc2独自のパスをすべて(`Inline`、`RC.annotate` + `Reuse` + `ConAltNative`、`MutualLoop`、`Loop`、`Sink`、`DualABI`)、同じリストに対する`traverse`として実行する。どのパスもエントリの追加や削除はせず、本体を書き換えるだけである。

ところが、これらの書き換えの結果、rc2の*最終的なプログラムの中で*定義が本当に到達不能になることがある。上流の解析は、これらのパスが走る前に確定しているので、そのことを知りようがない。原因は次の2つである。

- **`Compiler.RC2.InlineCExp`** は、対象になった呼び出し先の本体を、そのすべての呼び出し箇所に展開する(`rc2/doc/inlining.md`の適格性の規則「すべての呼び出し箇所」を参照)。元の定義は、呼び出し元が1つもないまま残る。Inlineより後段のどのパスも、このことに気づかない。そのため`Compiler.RC2.DualABI`のStage 3aは、このすでに死んでいる定義を、生きた関数と同じようにwrapperとworkerの組に分割してしまう(分割後の2つも、当然死んでいる)。
- **`Compiler.RC2.DualABI`のStage 3aのwrapper。** ネイティブ表現でディスパッチできる関数は、常にBoxedなwrapper(`IDRIS2RC2_Value*`でしか受け渡しできない呼び出し元のために残す)と、ネイティブの呼び出し規約を持つworkerに分けられる。Stage 4は、その関数の呼び出し箇所をworkerの直接呼び出しに書き換える。書き換えの対象は、末尾位置でないものに限られる(`rc2/doc/dual-abi.md`に書かれた恒久的な適用範囲の境界)。もともと末尾位置の呼び出し元がない関数では、呼び出し元がすべてworkerに付け替えられ、wrapperを呼ぶものが1つもなくなる。

どちらも、`rc2/tests/Test114Inline/DeadCodeInline.idr`で実際に起こることが確認されている。詳細は、このテストの冒頭コメントと、後述の「検証」を参照。

## パイプライン上の位置

```
Compiler.RC2.InlineCExp
  -> Compiler.RC2.RC.normalize/annotate + Reuse + ConAltNative
  -> Compiler.RC2.MutualLoop
  -> Compiler.RC2.Loop
  -> Compiler.RC2.Sink
  -> Compiler.RC2.DualABI          (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.Reuse            (re-check of dead offers)
  -> Compiler.RC2.DeadCode         (this module)
  -> Compiler.RC2.PushDown -> DupMerge -> LeafTail -> DeadVars -> FunDedup
  -> Compiler.RC2.Emit             (purely mechanical RCExp -> C)
```

このパスは`toRCDefs`の中で、`DualABI`とReuseの再チェックのあと、`PushDown`・`DupMerge`・`LeafTail`・`DeadVars`・`FunDedup`の前に実行される。`--directive nodeadcode`を指定するとこのパスを飛ばせる。ほかの任意のステージと同じ、A/B比較のための切り分けの規約である(`RC2.idr`の`toRCDefs`のドキュメントコメントを参照)。`--directive dumprcexpr`は、それらの最後のステージのあとのリストをダンプするので、ダンプは今も`Emit.generateCSourceFile`がこれから受け取るものそのままである。

## 設計

### ルート

`compileExpr`は、`MN "__mainExpression" 0`と`map fst (exported cdata)`をルートとして渡す。前者は、`footer`の`main()`が`__mainExpression_0()`として直接呼び出す、周知の名前である(`Compiler.Common`の`mainExpr`のドキュメントコメントを参照)。後者は`%export`された名前(`CompileData.exported`)で、上流の到達可能性解析のルートにも含まれている。rc2は`%export`を別途実装していないため、後者は現状では実際には常に`[]`である。それでも含めているのは、コストがかからず、将来この前提が変わったときの潜在的な落とし穴を避けられるからである。その落とし穴とは、外部から呼ばれることを意図した関数が、コンパイルされたプログラムの*内側*にも呼び出し元がないという理由で削除されてしまうことである。

### ウォーカー: `usedFunctionNamesD`

到達可能性の解析でたどる必要のある`Name`は、`RCExp`が直接呼び出しうる名前(`RAppName`、`RAppNameRep`)と、クロージャを作るためにファーストクラスの値として参照する名前(`RUnderApp`、および`ConstFold`が畳み込んだ`RCConstClosure`)である。`usedFunctionNamesD`は、これら4種類の`Name`に対するコールバックを、`Compiler.RC2.RCExp`の`foldRCNamesD`に渡しただけのものである。`foldRCNamesD`は、すべての`RCExp` / `RCLocal`のコンストラクタを網羅する、catch-allのないfoldで、`RCExp`側に1回だけ書かれている。`Compiler.RC2.Emit.ExternRefs`にある2つの前方宣言用のウォークも、これを共有している(同じ再帰に対して、異なる問いを立てている)。新しいコンストラクタを追加したときに更新が必要なのは`foldRCNamesR`の1か所だけで、ウォーカーごとに直す必要はない。また、`_ = empty`のように取りこぼしを黙って許す既定の節もない。そのため、`RLoop`の本体や`DualABI`が書き換えた呼び出し箇所の中にある参照が、気づかないうちに落とされることはない。この2か所は、このパスが最も注意して調べたい場所である。`RCExp.idr`にある従来の`freeLocalsR` / `countUsesR` / `usedConstructorsR`は、別々のままである。これらは、それぞれ別のもの(自由な`RCLocal`、使用回数、*コンストラクタ*名)を蓄積し、catch-allの節も持つ。そのため、ここには初めから適していなかった。

`Name`を持つコンストラクタのうち、2つは意図的に除外している。

- `RCon`の`Name`は*コンストラクタ*名であり、`defs`のキーである関数名とは別の名前空間に属する。
- `RExtPrim`の`Name`は、コンパイラが知っているプリミティブのセレクタ(`prim__newIORef`など。`Compiler.RC2.Emit`の`emitRC`の`RExtPrim`のケースを参照)を固定のホワイトリストとして持ち、文字列で照合される。`defs`で検索されることはない。

`RAppFFIInline`は`Name`をまったく持たない。呼び出し先は、自身の`ccs`フィールドから直接展開されたCのシンボルそのものであり、それに対応する`defs`のエントリがまだ存在するかどうかとは無関係である(この独立性がまさにこのパスが避けるべき落とし穴である理由は、後述の「見つかって修正したバグ」を参照)。

### 掃除: `pruneDeadDefs`

標準的なワークリストによるマークの段階(`markReachable`)を使う。`seen`は`roots`から始まり、`usedFunctionNamesD`を推移的にたどって増えていく。ワークリストを1回処理すれば推移閉包が*すべて*求まるので、不動点を求めるループは不要である。「直接の呼び出し元がゼロの定義を、変化がなくなるまで繰り返し取り除く」という定式化とは、この点が異なる。ルートからの到達可能性を見れば、死んだ連鎖全体を1回の走査で正しく除外できる。`A`が到達不能で、`B`が`A`からしか呼ばれないなら、連鎖が何段あっても、`B`はそもそもキューに入らない。

その後`pruneDeadDefs`は、到達可能な集合に入っていない`MkRCFun`のエントリをすべて落とす。`MkRCForeign` / `MkRCCon` / `MkRCError`は常に残す。`MkRCForeign`については後述の「適用範囲」を、`MkRCCon` / `MkRCError`については`DeadCode.idr`の冒頭の注記を参照。

## 適用範囲: `MkRCForeign`を意図的に除外している

このパスが`MkRCFun`について解決している「呼び出し元がゼロになる」という状況は、一見すると、`%foreign`宣言の、常にBoxedなwrapperのスタブ(`MkRCForeign`)でも起こるように思える。`Compiler.RC2.DualABI`の`ffiWorkerTable`と`inlineFFIWorkers` (Stage 3c/5)は、末尾位置でない適格な呼び出し箇所を*すべて*、`RAppFFIInline`の展開に直接書き換える。workerの`Name`は一切作られない。それなら、末尾位置の呼び出し元が残っていない宣言は、通常の関数のwrapperと同じように死んでいるはずではないか、というわけである。

しかし、これを削除する実装は厄介である(後述の「見つかって修正したバグ」の1を参照)。さらに、`Compiler.RC2.InlineCExp`と`Compiler.RC2.DualABI`を経由する限り、本当に死んだ`MkRCForeign`のエントリは、そもそも生じえない。

- `Compiler.RC2.InlineCExp`の適格性の条件は、呼び出し先の本体が呼び出しを含まないこと(`isCallFree`。`rc2/doc/inlining.md`を参照)である。したがって、FFI宣言を呼び出す関数がInlineの対象になることは*決して*ない。「このFFI宣言を呼ぶ唯一の関数が完全にインライン化されて消えた」という状況は、呼び出し元の本体にもともと呼び出しが1つもなかった場合にしか起こらないので、起こりえない。
- `Compiler.RC2.DualABI`のStage 3aのwrapper/workerの分割は、関数の元の本体*全体*を、FFI呼び出しも含めて、合成されたworkerに移す。wrapperの本体は、そのworkerへの薄い`RAppNameRep`にすぎない。そのため、wrapper自体が死んだ場合(これは`rc2/tests/Test114Inline/DeadCodeInline.idr`の`helper`のシナリオそのものである)でも、元の関数が行っていたFFI呼び出しはworkerの中に残る。その関数を実際に呼ぶものがある限り、呼び出し箇所の書き換え先がwrapperとworkerのどちらであっても、workerは到達可能なままである。

次のことを直接確かめた。このパスに、`ccs`(宣言自身の`%foreign`呼び出し規約を表す生の文字列)がまだ残っている`RAppFFIInline`の展開に現れるかどうかを追跡させ、名前による参照がなくても`ccs`が必要な`MkRCForeign`のエントリは残す、という版を作ってみた。しかし、実際には何も削除しなかった。これを発動させるために作ったテストはすべて`Inline` / `DualABI`を通り、上記の2つの仕組みによってエントリが残されたからである。テストされず、実際には到達しない複雑さを出荷するのではなく、この版は取り除いた。

**ただし、これで話が尽きるわけではない。** `Compiler.RC2.ConstFold`の`RConstCase`による「定数に対するcaseの畳み込み」(`foldConst`の`findConstAlt`)は、`Inline` / `DualABI`とはまったく無関係の*3つ目の*仕組みであり、部分木をまるごと捨てる。caseのスクルティニーが既知の定数に解決されると、ノード全体がマッチした枝の本体だけに置き換えられ、ほかのすべての枝は、中にある`%foreign`呼び出しも含めて、そのまま捨てられる。コードジェネレータ識別の分岐(`prim__codegen`を`Compiler.RC2.ConstFold`の`constExtPrimValue`が文字列リテラルに畳み込んだもの)や、真偽値の`RConstCase`に渡される畳み込み済みの比較は、まさにこの形にコンパイルされる。このようにして除去された分岐の中にしか呼び出し箇所がない宣言は、実際にすべての呼び出し元を失い、`MkRCForeign`も例外ではない。前述の、取り除いた`ccs`の追跡の仕組みであれば、この1つのケースは正しく捕捉できたはずだった。上のテストが通した2つの仕組みを経由しないだけである。これ以上は追求しないことにした。静的に除去される分岐の中にある、呼び出し箇所が1つだけの`%foreign`宣言という、まれな場合に限られ、取り除いた追跡の仕組みを復活させる価値はまだないと判断した。復活させる場合に必要な作業は、`TODO.md`の該当項目を参照。

## 見つかって修正したバグ

1. **まだ参照されている`MkRCForeign`を削除すると、そのヘッダ/ライブラリの登録が落ちる。** 最初の実装では、`pruneDeadDefs`が`MkRCFun`とまったく同じ到達可能性の判定で`MkRCForeign`のエントリも削除した。これを検証するテスト(`%foreign`宣言を末尾位置でない箇所から1回だけ呼び、その唯一の呼び出し箇所をStage 5でインライン化したもの)は、Cにコンパイルされたあと、解決できなくなったシンボルに対する暗黙の宣言エラーで失敗した。`%foreign`宣言が必要とする`#include`やライブラリの登録は、`Compiler.RC2.Emit.collectDeclarations`(Pass 1)が行うが、その際に反復する対象は`MkRCForeign`のエントリだけである。`RAppFFIInline`の呼び出し箇所は、呼び出しそのものを展開するのに必要な生の`ccs` / `fargs` / `ret`を持っているが、必要なヘッダについての情報は何も持たない。`MkRCForeign`のエントリを削除すると、その生のCシンボルを呼ぶ呼び出し箇所がまだ残っているのに、気づかないうちに登録だけが落ちた。これが、`ccs`を直接追跡する案(上記の「適用範囲」を参照)の動機になった。その後、この場合に削除しても何も得られない、という構造上のより根本的な理由が明らかになった。

2. **`%default total`が、このモジュールのすべての関数を拒否した。** このモジュールのマークとスイープのワークリスト(`markReachable`)は、リスト引数に対して構造的に減少しない。新しい名前が見つかるたびに、走査の途中でリストが伸びうるためである。また、`RCExp`を網羅するウォーク(`RCExp.idr`の`foldRCNamesR`)は、パターンの選択肢のリストへ`concatMap`で再帰するが、Idris2の停止性検査はこれを構造的再帰と見なさない。`RCExp`をウォークしたり、ワークリストのグラフを作ったりするほかの`Compiler.RC2.*`のモジュール(`RCExp.idr`、`MutualLoop.idr`、`Reuse.idr`)は、同じ理由で`%default total`ではなく`%default covering`を宣言している。`assert_total`に頼らず、これらに合わせて切り替えた。

## 検証

`rc2/tests/Test114Inline/DeadCodeInline.idr`は、Inlineで孤立した定義を扱う。その定義は、さらに死んだDualABIのwrapperとworkerの組へと広がる。また、以前は別ファイルだった`Test52DeadCodeDualABIWrapper.idr`(末尾位置の呼び出し元がないDualABIのwrapper)の検証内容も、このファイルが吸収している。このテストで、次の点を手作業で確認している。

- `--directive nodeadcode`の有無にかかわらず、機能面の出力は変わらない(このパスが変えるのは生成されるCの*サイズ*であり、プログラムの挙動ではない)。
- `--directive dumprcexpr`のダンプでは、このパスを有効にすると、対象の定義が完全に消えている。`--directive nodeadcode`ではダンプに残っており、実際に呼ばれていないことも、ダンプ内の呼び出し箇所を読んで確認した。
- 生成された`.c`自体にも、このパスを有効にすると、削除された名前に対応するC関数がまったく存在しない(マングル後の名前に対する`grep`で確認)。これは、`rc2/doc/dual-abi.md`がStage 5の削除を主張する際に掲げる「単なるデッドコードではない」という証明の水準と同じである。

このテストは、通常の`rc2/tests/verify.sh`のスモークスイートの一部である(自動的に検出され、特別な登録は不要)。また、スイート全体で`--directive nodeadcode`とのA/B比較を完全に実施しても問題なく通った。このパスがほかのどのテストの挙動も変えないことを、これで確認している。
