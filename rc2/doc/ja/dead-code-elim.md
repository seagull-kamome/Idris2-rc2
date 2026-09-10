# `Compiler.RC2.DeadCode`: 全プログラム・デッドコード削除

(原文: `doc/dead-code-elim.md`。内容が乖離した場合は原文を正とする。)

## 動機

`Compiler.Common.getCompileData` は、本家 Idris2 自身の*元の*
呼び出しグラフ(`mainExpr` 自身のクロージャ、および `%export` された
名前)にわたる到達可能性解析を通じて、rc2 の開始点となる
`List (Name, LiftedDef)` を一度計算する。`Compiler.RC2.RC2` の
`toRCDefs` はその後、rc2 自身の全パス(`Inline`、
`RC.annotate`+`Reuse`+`ConAltNative`、`MutualLoop`、`Loop`、`Sink`、
`DualABI`)をその同じリストへの `traverse` として実行する -- どれも
エントリを追加・削除せず、本体をその場で書き換えるだけ。

しかしそれらの書き換えの一部は、ある定義を*rc2 自身の最終
プログラム内で*本当に到達不能にする。その方法は、本家の解析
(これらが実行される前に確定している)には知りようがない:

- **`Compiler.RC2.Inline`** は適格な呼び出し先の本体を、その*全ての*
  呼び出し箇所へ差し込む(`rc2/doc/inlining.md` 自身の「全呼び出し
  箇所」適格性ルール)。元の定義は呼び出し元がゼロのまま残される --
  そして Inline より下流の何もこれが起きたことを認識していないので、
  `Compiler.RC2.DualABI` 自身の Stage 3a は、その今や死んでいる定義を、
  生きた関数と同じように、それ自身の(同様に死んでいる)ラッパー
  +ワーカーのペアへ嬉々として分割し続ける。
- **`Compiler.RC2.DualABI` の Stage 3a ラッパー。** ネイティブ表現
  ディスパッチに適格な関数は、常に Boxed なラッパー(`IDRIS2RC2_Value*`
  しか供給/消費できない呼び出し元のために保持される)と、ネイティブ
  呼び出し規約のワーカーを得る。Stage 4 はその関数自身の呼び出し
  箇所をワーカーの直接呼び出しへ書き換える -- 必然的に非末尾位置の
  ものだけ(`rc2/doc/dual-abi.md` 自身の恒久的なスコープ境界)。
  もしその関数がそもそも末尾位置の呼び出し元を持っていなければ、
  その全ての呼び出し元がワーカーへリダイレクトされ、ラッパー自身は
  呼び出し元がゼロで終わる。

どちらも `rc2/tests/Test51DeadCode*`/`Test52DeadCode*` によって実在が
確認されている -- それら自身のヘッダコメントと下記「検証」を参照。

## パイプライン位置

```
Compiler.RC2.Inline
  -> Compiler.RC2.RC.normalize/annotate + Reuse + ConAltNative
  -> Compiler.RC2.MutualLoop
  -> Compiler.RC2.Loop
  -> Compiler.RC2.Sink
  -> Compiler.RC2.DualABI          (ワーカー/ラッパー合成、呼び出し箇所書き換え)
  -> Compiler.RC2.DeadCode         (本モジュール -- 最終段階)
  -> Compiler.RC2.Emit             (純粋に機械的な RCExp -> C)
```

`toRCDefs` 自身の最後のステップとして、`Emit.generateCSourceFile` が
まさに消費しようとしている `List (Name, RCDef)` に対して実行される --
そのため `--directive dumprcexpr` 自身の主張(「generateCSourceFile
がまさに消費しようとしているもの」)は、このパスがパイプラインに
あっても*それにもかかわらず*ではなく、真であり続ける。
`--directive nodeadcode` はそれをスキップする。他の全ての任意段階と
同じ A/B 切り分けの慣習(`RC2.idr` 自身の `toRCDefs` ドキュメント
コメント)。

## 設計

### ルート

`compileExpr` は `MN "__mainExpression" 0`(`footer` の `main()` が
`__mainExpression_0()` として直接呼ぶ周知の名前 -- `Compiler.Common`
自身の `mainExpr` に関するドキュメントコメント)に加えて
`map fst (exported cdata)`(`%export` された名前 --
`CompileData.exported`、本家自身の到達可能性ルートにも既に含まれて
いる)を供給する。rc2 はそれ以外に `%export` を実装していないので、
この後半は現状、実際には常に `[]` である。それでも含めている。
コストがゼロで、それがいつか変わった場合の潜在的な罠を避けるため
である -- コンパイル済みプログラムの*内部*でもその関数を呼ぶものが
無いという理由で、外部から呼ばれることを意図した関数を削除して
しまうという罠。

### ウォーカー: `usedFunctionNamesD`

到達可能性が追う必要がある `Name` とは、`RCExp` が直接呼ぶかも
しれない(`RAppName`、`RAppNameRep`)、あるいはクロージャを構築する
ための第一級の値として参照するかもしれない(`RUnderApp`、または
`ConstFold` が畳み込んだ `RCConstClosure`)あらゆる名前である。
`usedFunctionNamesD` は、その 4 つの `Name` コールバックを
`Compiler.RC2.RCExp` の `foldRCNamesD` に渡しただけである --
全ての `RCExp`/`RCLocal` コンストラクタにわたる、網羅的で
catch-all のない fold で、そこに 1 度だけ書かれ、
`Compiler.RC2.Emit.ExternRefs` の 2 つの前方宣言ウォーク(同じ
再帰に別の問いをする)と共有される。新しいコンストラクタは
`foldRCNamesR` の 1 箇所の更新を強制する、ウォーカーごとに 1 箇所
ではない。そして `RLoop` の本体や `DualABI` で書き換えられた
呼び出し箇所の中に住む参照を黙って落とす `_ = empty` の枝はない
-- まさにこのパスが最も見る必要がある 2 箇所である。`RCExp.idr`
の古い `freeLocalsR`/`countUsesR`/`usedConstructorsR` は別のまま:
それぞれ別のもの(自由 `RCLocal`、使用回数、*コンストラクタ*名)
を集積し、キャッチオールを持つので、ここには最初から合わなかった。

`Name` を持つ 2 つのコンストラクタは意図的に除外されている:

- `RCon`/`RCConstCon` 自身の `Name` は*コンストラクタ*名であり、
  `defs` 自身の関数名キーとは別の名前空間。
- `RExtPrim` の `Name` は、コンパイラが知る固定のホワイトリストに
  ある基本セレクタ(`prim__newIORef` など -- `Compiler.RC2.Emit`
  自身の `emitRC` の `RExtPrim` ケース参照)の 1 つで、そのホワイト
  リストに対して文字列で照合され、`defs` で引かれることは決してない。

`RAppFFIInline` は `Name` を一切持たない -- そのターゲットは、
それ自身の `ccs` フィールドから直接差し込まれるリテラルな C
シンボルであり、`defs` エントリがまだそれに対して存在するか
どうかとは独立している(その独立性がまさにこのパスが避けねば
ならない罠である理由は下記「見つかったバグ」参照)。

### スイープ: `pruneDeadDefs`

標準的なワークリストのマークフェーズ(`markReachable`): `seen` は
`roots` から始まり、`usedFunctionNamesD` を推移的に辿って成長する。
ワークリストに
対する 1 回のパスで*全ての*推移的閉包を見つける -- 「直接の
呼び出し元がゼロの定義を、何も変わらなくなるまで繰り返し削除
する」という定式化とは異なり、不動点ループは不要。ルートからの
到達可能性は、既に 1 回の走査でデッドチェーン全体を正しく除外
する: もし `A` が到達不能で `B` が `A` からしか呼ばれていない
なら、チェーンが何リンク長であろうと、`B` は単にキューに入れ
られない。

`pruneDeadDefs` はその後、到達可能集合に無い全ての `MkRCFun`
エントリを落とす。`MkRCForeign`/`MkRCCon`/`MkRCError` は常に保持
される -- `MkRCForeign` については下記「スコープ」を、
`MkRCCon`/`MkRCError` については `DeadCode.idr` 自身のヘッダノートを
参照。

## スコープ: `MkRCForeign` は意図的に除外

このパスが `MkRCFun` に対して修正するのとまったく同じ「呼び出し元が
ゼロ」の状況は、一見すると `%foreign` 宣言自身の常に Boxed な
ラッパースタブ(`MkRCForeign`)についても生じるはずに見える:
`Compiler.RC2.DualABI` の `ffiWorkerTable` + `inlineFFIWorkers`
(Stage 3c/5)は、*全ての*適格な非末尾呼び出し箇所を直接
`RAppFFIInline` 差し込みへ書き換え、合成されたワーカーの `Name` は
一切作られない -- 末尾位置の呼び出し元が残っていない宣言は、
確実に、通常の関数のラッパーと同じくらい死んで終わるのでは?

それを刈り取るのは実装が厄介で(下記「見つかったバグ」#1 参照)、
かつ -- 特に `Compiler.RC2.Inline`/`Compiler.RC2.DualABI` 経由では
-- 真に死んだ `MkRCForeign` エントリは実際には全く生じ得ない:

- `Compiler.RC2.Inline` 自身の適格性は、呼び出し先の本体が呼び出し
  フリー(`isCallFree`、`rc2/doc/inlining.md`)であることを要求する。
  したがって、それ自身が FFI 宣言を呼ぶ関数は*決して* Inline 適格
  にならない -- 「この FFI 宣言を呼ぶ唯一の関数が完全にインライン化
  されて消えた」は起こりようがない。その状況は、呼び出し元が
  そもそも自身の本体に呼び出しをゼロ個持っていたことを要求する
  からである。
- `Compiler.RC2.DualABI` の Stage 3a ラッパー/ワーカー分割は、
  関数の*本体全体* -- FFI 呼び出しを含む全て -- を合成されたワーカーへ
  移す。ラッパー自身の本体は、そのワーカーへの薄い `RAppNameRep` に
  すぎない。だからラッパー自身が死んだとき(まさに
  `rc2/tests/Test52DeadCode*` 自身のシナリオ)でも、元の関数が
  行った FFI 呼び出しはまだワーカーの中に座っており、そのワーカーは、
  何かが本当にその関数を呼ぶ限り -- ラッパーであれワーカーであれ、
  呼び出し箇所がどちらをターゲットに書き換えられたかによらず --
  到達可能なまま。

直接確認済み: このパスの、生き残った `RAppFFIInline` 差し込みの
中にどの `ccs`(宣言自身の生の `%foreign` 呼び出し規約文字列)が
まだ現れるかも追跡し、名前参照が無くても `ccs` がまだ必要な
`MkRCForeign` エントリを保持するバージョンは、実際には何も削除
しなかった -- それを引き起こすために構築された全てのテストは
`Inline`/`DualABI` を通り、まさに上記の 2 つの機構を通じてエントリを
生かし続けた。テストされない、実際には到達不能な複雑さとして出荷
するのではなく、削除した。

**とはいえこれで話は終わりではない** -- `Compiler.RC2.ConstFold`
自身の `RConstCase` の case-of-constant 畳み込み(`foldConst` の
`findConstAlt`)は、`Inline`/`DualABI` の完全に外側にある*第 3 の*
機構で、部分木を丸ごと捨てる: case のスクルティニーが既知の定数に
解決されると、ノード全体が一致した alt の本体だけに置き換えられ、
他の全ての alt -- その中のあらゆる `%foreign` 呼び出しも含めて -- は
そのまま捨てられる。codegen-identity 分岐(`Compiler.RC2.ConstFold`
の `constExtPrimValue` によってリテラル文字列へ畳まれた
`prim__codegen`)や、真偽値の `RConstCase` へ供給される畳まれた
比較は、まさにこの形へコンパイルされる。*唯一の*呼び出し箇所が
この方法で除去された分岐の中に座っている宣言は、`MkRCForeign` を
含めて、本当に全ての呼び出し元を失う -- 上記で説明した削除された
`ccs` 追跡機構は、この 1 ケースを正しく捕捉していただろう。ただし
上のテストがたまたま行使した 2 つの機構を通じてではない。意図的に
これ以上追求していない -- 十分に稀(静的に除去された分岐の中の、
呼び出し箇所が 1 つだけの `%foreign` 宣言)なので、削除された
追跡を復活させるのはまだ割に合わないと判断した。復活に何が必要か
は `TODO.md` 自身のこの件のエントリを参照。

## 見つかって修正されたバグ

1. **まだ参照されている `MkRCForeign` を刈り取ると、そのヘッダ/
   ライブラリ登録が落ちる。** 最初の試みでは、`MkRCFun` とまったく
   同じ到達可能性テストを使って、`pruneDeadDefs` に `MkRCForeign`
   エントリも削除させた。それを行使するテスト(1 回だけ非末尾位置
   から呼ばれ、その唯一の呼び出し箇所が Stage 5 経由でインライン化
   された `%foreign` 宣言)は、今や解決不能なシンボルに対する
   暗黙宣言エラーで失敗する C にコンパイルされた:
   `Compiler.RC2.Emit.collectDeclarations`(Pass 1)が、`%foreign`
   宣言自身の `#include`/ライブラリの必要性を登録するものであり、
   それを `MkRCForeign` エントリの反復によって特に行う --
   `RAppFFIInline` 自身の呼び出し箇所は、呼び出し自体を差し込むのに
   必要な生の `ccs`/`fargs`/`ret` を持つが、それが必要とする
   ヘッダについては何も持たない。`MkRCForeign` エントリの削除は、
   その生の C シンボルを呼ぶ呼び出し箇所がまだ確かに存在している
   のに、その登録を黙って落とした。これが `ccs` を直接追跡する
   動機になった(上記「スコープ」参照) -- そしてそれが今度は、
   いずれにせよ削除がここでは実際には役立たない、より深い構造的な
   理由を浮上させた。

2. **`%default total` がこのモジュールの全関数を拒否した。**
   このモジュールのマーク&スイープのワークリスト(`markReachable`)は、
   自身のリスト引数に対して構造的に減少しない(新しい名前が
   発見されると走査の途中で成長しうる)。また網羅的な `RCExp`
   ウォーク(`RCExp.idr` の `foldRCNamesR`)は、パターン代替リストへ
   `concatMap` 経由で再帰し、それを Idris2 の停止性チェッカは
   構造的再帰として見通せない。`RCExp` を歩く/ワークリストグラフを構築する他の
   全ての `Compiler.RC2.*` モジュール(`RCExp.idr`、`MutualLoop.idr`、
   `Reuse.idr`)は、まさにこの理由で既に `%default covering` を
   宣言していて `total` ではない -- `assert_total` に手を伸ばすの
   ではなく、それに合わせて切り替えた。

## 検証

`rc2/tests/Test51DeadCodeInline.idr`(Inline によって孤児化された
定義。それ自身がさらに、自身の死んだ DualABI ラッパー+ワーカーの
ペアへ扇状に広がり、また末尾位置の呼び出し元を持たない DualABI
ラッパーに対する、かつての別個の `Test52DeadCodeDualABIWrapper.idr`
のカバレッジも吸収している)は、手作業で以下を確認する:

- `--directive nodeadcode` の有無どちらでも機能的な出力が不変
  (このパスは生成 C の*サイズ*を変えるのであって、プログラムの
  挙動は決して変えない);
- `--directive dumprcexpr` 自身のダンプが、パス有効時には対象定義が
  完全に不在であること、`--directive nodeadcode` 時には存在し
  (かつ本当に呼ばれていない -- ダンプ自身の呼び出し箇所を読んで
  確認済み)であることを示す;
- 生成された `.c` 自体が、パス有効時には刈り取られた名前に対する
  C 関数を一切持たない(マングルされた名前に対する `grep`)。これは
  `rc2/doc/dual-abi.md` 自身の Stage 5 削除の主張に対する「単なる
  デッドコードではない」という証明基準に一致する。

両テストは通常の `rc2/tests/verify.sh` スモークスイートの一部
(自動発見、特別な登録は不要)で、スイート全体にわたる完全な
`--directive nodeadcode` A/B 比較の下でクリーンに実行され、この
パスが他のどのテストの挙動も決して変えないことを確認している。
