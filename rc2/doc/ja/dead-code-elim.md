# `Compiler.RC2.DeadCode`: プログラム全体のデッドコード除去

(原文: `doc/dead-code-elim.md`。内容が乖離した場合は原文を正とする。)

## 動機

`Compiler.Common.getCompileData` は、rc2 が最初に受け取る `List (Name, LiftedDef)` を
1回だけ計算する。上流 Idris2 自身の到達可能性解析を、*元の*呼び出しグラフ
(`mainExpr` から到達できる範囲に、`%export` された名前を加えたもの)に対して
適用するものである。続いて `Compiler.RC2.RC2` の `toRCDefs` が、rc2 独自のパスを
すべて(`Inline`、`RC.annotate` + `Reuse` + `ConAltNative`、`MutualLoop`、`Loop`、
`Sink`、`DualABI`)、同じリストに対する `traverse` として実行する。どのパスも
エントリの追加や削除はせず、本体を書き換えるだけである。

ところが、これらの書き換えの結果、rc2 の*最終的なプログラムの中で*定義が本当に
到達不能になることがある。上流の解析は、これらのパスが走る前に確定しているので、
そのことを知りようがない。原因は次の2つである。

- **`Compiler.RC2.InlineCExp`** は、対象になった呼び出し先の本体を、そのすべての
  呼び出し箇所に展開する(`rc2/doc/inlining.md` の適格性の規則「すべての呼び出し
  箇所」を参照)。元の定義は、呼び出し元が1つもないまま残る。Inline より後段の
  どのパスも、このことに気づかない。そのため `Compiler.RC2.DualABI` の Stage 3a は、
  このすでに死んでいる定義を、生きた関数と同じように wrapper と worker の組に分割
  してしまう(分割後の2つも、当然死んでいる)。
- **`Compiler.RC2.DualABI` の Stage 3a の wrapper。** ネイティブ表現でディスパッチ
  できる関数は、常に Boxed な wrapper(`IDRIS2RC2_Value*` でしか受け渡しできない
  呼び出し元のために残す)と、ネイティブの呼び出し規約を持つ worker に分けられる。
  Stage 4 は、その関数の呼び出し箇所を worker の直接呼び出しに書き換える。書き換え
  の対象は、末尾位置でないものに限られる(`rc2/doc/dual-abi.md` に書かれた恒久的な
  適用範囲の境界)。もともと末尾位置の呼び出し元がない関数では、呼び出し元がすべて
  worker に付け替えられ、wrapper を呼ぶものが1つもなくなる。

どちらも、`rc2/tests/Test51DeadCode*` / `Test52DeadCode*` で実際に起こることが確認
されている。詳細は、これらのテストの冒頭コメントと、後述の「検証」を参照。

## パイプライン上の位置

```
Compiler.RC2.InlineCExp
  -> Compiler.RC2.RC.normalize/annotate + Reuse + ConAltNative
  -> Compiler.RC2.MutualLoop
  -> Compiler.RC2.Loop
  -> Compiler.RC2.Sink
  -> Compiler.RC2.DualABI          (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.DeadCode         (this module -- final stage)
  -> Compiler.RC2.Emit             (purely mechanical RCExp -> C)
```

このパスは `toRCDefs` の最後のステップとして、`Emit.generateCSourceFile` がこれから
受け取る `List (Name, RCDef)` そのものに対して実行される。そのため、
`--directive dumprcexpr` の説明(「generateCSourceFile がこれから受け取るものその
まま」)は、このパスがパイプラインに入っても、そのまま成り立つ。「このパスがあるにも
かかわらず成り立つ」のではなく、「このパスを含めて成り立つ」のである。
`--directive nodeadcode` を指定するとこのパスを飛ばせる。ほかの任意のステージと同じ、
A/B 比較のための切り分けの規約である(`RC2.idr` の `toRCDefs` のドキュメントコメント
を参照)。

## 設計

### ルート

`compileExpr` は、`MN "__mainExpression" 0` と `map fst (exported cdata)` をルートとして
渡す。前者は、`footer` の `main()` が `__mainExpression_0()` として直接呼び出す、
周知の名前である(`Compiler.Common` の `mainExpr` のドキュメントコメントを参照)。
後者は `%export` された名前(`CompileData.exported`)で、上流の到達可能性解析のルート
にも含まれている。rc2 は `%export` を別途実装していないため、後者は現状では実際には
常に `[]` である。それでも含めているのは、コストがかからず、将来この前提が変わった
ときの潜在的な落とし穴を避けられるからである。その落とし穴とは、外部から呼ばれる
ことを意図した関数が、コンパイルされたプログラムの*内側*にも呼び出し元がないという
理由で削除されてしまうことである。

### ウォーカー: `usedFunctionNamesD`

到達可能性の解析でたどる必要のある `Name` は、`RCExp` が直接呼び出しうる名前
(`RAppName`、`RAppNameRep`)と、クロージャを作るためにファーストクラスの値として
参照する名前(`RUnderApp`、および `ConstFold` が畳み込んだ `RCConstClosure`)である。
`usedFunctionNamesD` は、これら4種類の `Name` に対するコールバックを、
`Compiler.RC2.RCExp` の `foldRCNamesD` に渡しただけのものである。`foldRCNamesD` は、
すべての `RCExp` / `RCLocal` のコンストラクタを網羅する、catch-all のない fold で、
`RCExp` 側に1回だけ書かれている。`Compiler.RC2.Emit.ExternRefs` にある2つの前方宣言用
のウォークも、これを共有している(同じ再帰に対して、異なる問いを立てている)。新しい
コンストラクタを追加したときに更新が必要なのは `foldRCNamesR` の1か所だけで、
ウォーカーごとに直す必要はない。`_ = empty` のような、取りこぼしを黙って許す既定の節もないので、
`RLoop` の本体や `DualABI` が書き換えた呼び出し箇所の中にある参照が、気づかないうちに
落とされることもない。この2か所は、このパスが最も注意して調べたい場所である。
`RCExp.idr` にある従来の `freeLocalsR` / `countUsesR` / `usedConstructorsR` は、
別々のままである。これらは、それぞれ別のもの(自由な `RCLocal`、使用回数、
*コンストラクタ*名)を蓄積し、catch-all の節も持つ。そのため、ここには初めから
適していなかった。

`Name` を持つコンストラクタのうち、2つは意図的に除外している。

- `RCon` の `Name` は*コンストラクタ*名であり、`defs` のキーである関数名とは別の
  名前空間に属する。
- `RExtPrim` の `Name` は、コンパイラが知っているプリミティブのセレクタ
  (`prim__newIORef` など。`Compiler.RC2.Emit` の `emitRC` の `RExtPrim` のケースを
  参照)を固定のホワイトリストとして持ち、文字列で照合される。`defs` で検索される
  ことはない。

`RAppFFIInline` は `Name` をまったく持たない。呼び出し先は、自身の `ccs` フィールド
から直接展開された C のシンボルそのものであり、それに対応する `defs` のエントリが
まだ存在するかどうかとは無関係である(この独立性がまさにこのパスが避けるべき落とし穴
である理由は、後述の「見つかって修正したバグ」を参照)。

### 掃除: `pruneDeadDefs`

標準的なワークリストによるマークの段階(`markReachable`)を使う。`seen` は `roots`
から始まり、`usedFunctionNamesD` を推移的にたどって増えていく。ワークリストを
1回処理すれば推移閉包が*すべて*求まるので、不動点を求めるループは不要である。
「直接の呼び出し元がゼロの定義を、変化がなくなるまで繰り返し取り除く」という定式化
とは、この点が異なる。ルートからの到達可能性を見れば、死んだ連鎖全体を1回の走査で
正しく除外できる。`A` が到達不能で、`B` が `A` からしか呼ばれないなら、連鎖が何段
あっても、`B` はそもそもキューに入らない。

その後 `pruneDeadDefs` は、到達可能な集合に入っていない `MkRCFun` のエントリをすべて
落とす。`MkRCForeign` / `MkRCCon` / `MkRCError` は常に残す。`MkRCForeign` については
後述の「適用範囲」を、`MkRCCon` / `MkRCError` については `DeadCode.idr` の冒頭の注記を
参照。

## 適用範囲: `MkRCForeign` を意図的に除外している

このパスが `MkRCFun` について解決している「呼び出し元がゼロになる」という状況は、
一見すると、`%foreign` 宣言の、常に Boxed な wrapper のスタブ(`MkRCForeign`)でも
起こるように思える。`Compiler.RC2.DualABI` の `ffiWorkerTable` と `inlineFFIWorkers`
(Stage 3c/5)は、末尾位置でない適格な呼び出し箇所を*すべて*、`RAppFFIInline` の
展開に直接書き換える。worker の `Name` は一切作られない。それなら、末尾位置の
呼び出し元が残っていない宣言は、通常の関数の wrapper と同じように死んでいるはず
ではないか、というわけである。

しかし、これを削除する実装は厄介である(後述の「見つかって修正したバグ」の1を参照)。
さらに、`Compiler.RC2.InlineCExp` と `Compiler.RC2.DualABI` を経由する限り、本当に
死んだ `MkRCForeign` のエントリは、そもそも生じえない。

- `Compiler.RC2.InlineCExp` の適格性の条件は、呼び出し先の本体が呼び出しを含まない
  こと(`isCallFree`。`rc2/doc/inlining.md` を参照)である。したがって、FFI 宣言を
  呼び出す関数が Inline の対象になることは*決して*ない。「この FFI 宣言を呼ぶ唯一
  の関数が完全にインライン化されて消えた」という状況は、呼び出し元の本体にもともと
  呼び出しが1つもなかった場合にしか起こらないので、起こりえない。
- `Compiler.RC2.DualABI` の Stage 3a の wrapper/worker の分割は、関数の元の本体
  *全体*を、FFI 呼び出しも含めて、合成された worker に移す。wrapper の本体は、その
  worker への薄い `RAppNameRep` にすぎない。そのため、wrapper 自体が死んだ場合
  (これは `rc2/tests/Test52DeadCode*` のシナリオそのものである)でも、元の関数が行っ
  ていた FFI 呼び出しは worker の中に残る。その関数を実際に呼ぶものがある限り、
  呼び出し箇所の書き換え先が wrapper と worker のどちらであっても、worker は到達可能
  なままである。

次のことを直接確かめた。このパスに、`ccs`(宣言自身の `%foreign` 呼び出し規約を表す
生の文字列)がまだ残っている `RAppFFIInline` の展開に現れるかどうかを追跡させ、名前
による参照がなくても `ccs` が必要な `MkRCForeign` のエントリは残す、という版を作って
みた。しかし、実際には何も削除しなかった。これを発動させるために作ったテストはすべて
`Inline` / `DualABI` を通り、上記の2つの仕組みによってエントリが残されたからである。
テストされず、実際には到達しない複雑さを出荷するのではなく、この版は取り除いた。

**ただし、これで話が尽きるわけではない。** `Compiler.RC2.ConstFold` の `RConstCase`
による「定数に対する case の畳み込み」(`foldConst` の `findConstAlt`)は、`Inline` /
`DualABI` とはまったく無関係の*3つ目の*仕組みであり、部分木をまるごと捨てる。
case のスクルティニーが既知の定数に解決されると、ノード全体がマッチした枝の本体だけ
に置き換えられ、ほかのすべての枝は、中にある `%foreign` 呼び出しも含めて、そのまま
捨てられる。コードジェネレータ識別の分岐(`prim__codegen` を `Compiler.RC2.ConstFold`
の `constExtPrimValue` が文字列リテラルに畳み込んだもの)や、真偽値の `RConstCase`
に渡される畳み込み済みの比較は、まさにこの形にコンパイルされる。このようにして
除去された分岐の中にしか呼び出し箇所がない宣言は、実際にすべての呼び出し元を失い、
`MkRCForeign` も例外ではない。前述の、取り除いた `ccs` の追跡の仕組みであれば、この
1つのケースは正しく捕捉できたはずだった。上のテストが通した2つの仕組みを経由しない
だけである。これ以上は追求しないことにした。静的に除去される分岐の中にある、呼び出し
箇所が1つだけの `%foreign` 宣言という、まれな場合に限られ、取り除いた追跡の仕組みを
復活させる価値はまだないと判断した。復活させる場合に必要な作業は、`TODO.md` の該当
項目を参照。

## 見つかって修正したバグ

1. **まだ参照されている `MkRCForeign` を削除すると、そのヘッダ/ライブラリの登録が
   落ちる。** 最初の実装では、`pruneDeadDefs` が `MkRCFun` とまったく同じ到達可能性
   の判定で `MkRCForeign` のエントリも削除した。これを検証するテスト(`%foreign` 宣言
   を末尾位置でない箇所から1回だけ呼び、その唯一の呼び出し箇所を Stage 5 でインライン
   化したもの)は、C にコンパイルされたあと、解決できなくなったシンボルに対する暗黙の
   宣言エラーで失敗した。`%foreign` 宣言が必要とする `#include` やライブラリの登録は、
   `Compiler.RC2.Emit.collectDeclarations`(Pass 1)が行うが、その際に反復する対象は
   `MkRCForeign` のエントリだけである。`RAppFFIInline` の呼び出し箇所は、呼び出しその
   ものを展開するのに必要な生の `ccs` / `fargs` / `ret` を持っているが、必要なヘッダに
   ついての情報は何も持たない。`MkRCForeign` のエントリを削除すると、その生の C シンボル
   を呼ぶ呼び出し箇所がまだ残っているのに、気づかないうちに登録だけが落ちた。これが、
   `ccs` を直接追跡する案(上記の「適用範囲」を参照)の動機になった。その後、削除に
   よって何も得られないのは、この箇所では構造上そうなっているからだ、という、より
   根本的な理由が明らかになった。

2. **`%default total` が、このモジュールのすべての関数を拒否した。** このモジュール
   のマークとスイープのワークリスト(`markReachable`)は、リスト引数に対して構造的に
   減少しない。新しい名前が見つかるたびに、走査の途中でリストが伸びうるためである。
   また、`RCExp` を網羅するウォーク(`RCExp.idr` の `foldRCNamesR`)は、パターンの
   選択肢のリストへ `concatMap` で再帰するが、Idris2 の停止性検査はこれを構造的再帰
   と見なさない。`RCExp` をウォークしたり、ワークリストのグラフを作ったりするほかの
   `Compiler.RC2.*` のモジュール(`RCExp.idr`、`MutualLoop.idr`、`Reuse.idr`)は、
   同じ理由で `%default total` ではなく `%default covering` を宣言している。
   `assert_total` に頼らず、これらに合わせて切り替えた。

## 検証

`rc2/tests/Test114Inline/DeadCodeInline.idr` は、Inline で孤立した定義を扱う。その
定義は、さらに死んだ DualABI の wrapper と worker の組へと広がる。また、以前は別
ファイルだった `Test52DeadCodeDualABIWrapper.idr`(末尾位置の呼び出し元がない
DualABI の wrapper)の検証内容も、このファイルが吸収している。このテストで、次の点を
手作業で確認している。

- `--directive nodeadcode` の有無にかかわらず、機能面の出力は変わらない(このパスが
  変えるのは生成される C の*サイズ*であり、プログラムの挙動ではない)。
- `--directive dumprcexpr` のダンプでは、このパスを有効にすると、対象の定義が完全に
  消えている。`--directive nodeadcode` ではダンプに残っており、実際に呼ばれていない
  ことも、ダンプ内の呼び出し箇所を読んで確認した。
- 生成された `.c` 自体にも、このパスを有効にすると、削除された名前に対応する C 関数が
  まったく存在しない(マングル後の名前に対する `grep` で確認)。これは、
  `rc2/doc/dual-abi.md` が Stage 5 の削除を主張する際に掲げる「単なるデッドコード
  ではない」という証明の水準と同じである。

2つのテストはいずれも、通常の `rc2/tests/verify.sh` のスモークスイートの一部である
(自動的に検出され、特別な登録は不要)。また、スイート全体で `--directive nodeadcode`
との A/B 比較を完全に実施しても問題なく通った。このパスがほかのどのテストの挙動も
変えないことを、これで確認している。
