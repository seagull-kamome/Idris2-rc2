# rc2 のディレクティブシステム(`--directive VALUE` / `%cg rc2 <directive>`)

(原文: `doc/directives.md`。内容が乖離した場合は原文を正とする。)

rc2 が認識する全ディレクティブのリファレンス: 各ディレクティブが
何をするか、なぜ存在するか、そして実際にどう渡すか。
`doc/reading-the-ir.md`(`dumprcexpr` 自身の*出力*フォーマットを
詳しく説明する)の姉妹編 -- 本書はディレクティブ機構そのものと、
その上に構築された全ディレクティブについて扱う。

## 1. 機構

Idris2 には汎用でバックエンド非依存の `%cg <codegen> <directive>`
ソースプラグマ(パースされ、推移的インポートをまたいで集約され、
TTC に永続化される)と、繰り返し可能な CLI `--directive VALUE`
フラグがある -- どちらも完全に汎用の本家機構であり
(`Core.Context.addDirective`/`cgdirectives`、`Idris.Session` の CLI
パース)、本書で説明するどのディレクティブ(rc2 専用のものを含む)を
サポートするためにも idris2-src の変更は不要だった。
`Compiler.RC2.RC2.compileExpr` は両ソースの和集合を、先頭で一度、
`getDirectives (Other "rc2")`(rc2 自身の登録済みコードジェン名)
経由で読み取り、以下の全ディレクティブが照合される単一の
`directiveList : List String` にする。

```idris2
%cg rc2 noloop
%cg rc2 dumprcexpr
%cg rc2 extraRuntime=path/to/helpers.c
```

```sh
idris2-rc2 --cg rc2 --directive noloop --directive dumprcexpr Program.idr -o program
```

本家の RefC は `--directive`/`%cg` を一切何にも読まない
(`idris2-src/src/Compiler/RefC/RefC.idr` には `getDirectives`/
`getSession` を呼ぶものが無い) -- 本書の全ディレクティブは、
挙動が rc2 専用であるか、あるいは(`extraRuntime`)RefC がたまたま
消費していない汎用機構を rc2 が単に利用しているだけである。

## 2. パイプライン段階の無効化(`no<stagename>`)

`Compiler.RC2.RC2.toRCDefs` を手で編集して `idris2-rc2` を再ビルド
することなく、A/B での回帰切り分け(「観測された差分/リークは特定の
1 パスに遡れるか」)を行うため。各段階は純粋に加算的/任意的である:
それをスキップしても*正しい*(最適化は劣り、本家 `idris2 --cg refc`
自身の出力形状とはもうバイト単位で一致しないかもしれないが)C を
生成するはず -- どの段階も、正しさのためには下流の何からも要求
されておらず、それ自身が提供する最適化のためだけに存在する。
設計上粗い: 関数ごと/ノードごとの細かい制御ではなく、段階全体の
オン/オフスイッチ。

| ディレクティブ | 無効化するもの |
|---|---|
| `noinline` | `Compiler.RC2.Inline` の全プログラムインライン化(`doc/inlining.md`)。 |
| `noconstfold` | `Compiler.RC2.ConstFold` の全プログラム不動点畳み込み -- 算術/比較/コンストラクタ/クロージャ/CAF の畳み込み*および*定数 `ExtPrim` 畳み込み(`prim__codegen`)。後者は `Compiler.RC2.ConstExtPrim` パスが統合されて以降、このディレクティブでゲートされる。 |
| `noconaltnative` | `Compiler.RC2.ConAltNative` のネイティブシャドウ・フィールドキャッシュ(`doc/con-alt-native.md`)。 |
| `nomutualloop` | `Compiler.RC2.MutualLoop` の相互末尾再帰マージ。 |
| `noloop` | `Compiler.RC2.Loop` の自己末尾呼び出し -> `goto` 変換、およびネイティブシャドウ/ループ不変量の昇格(`doc/loop-conversion.md`)。 |
| `nosink` | `Compiler.RC2.Sink` のブランチローカル・シンキング(`doc/branch-sinking.md`)。 |
| `nodualabi` | `Compiler.RC2.DualABI` のワーカー/ラッパー合成*と*その呼び出し箇所の書き換えの両方をまとめて -- 書き換えは合成段階が構築するワーカーテーブルを必要とするので、分割しても意味が無い(`doc/dual-abi.md`)。 |
| `nodeadcode` | `Compiler.RC2.DeadCode` による、呼び出し元がゼロになった定義の刈り取り(`doc/dead-code-elim.md`)。 |
| `nodupmerge` | `Compiler.RC2.DupMerge` による、複数個の個別 `RDup` ノードを 1 つのより高い `extra` の `RDup` へまとめる処理。 |

このリストに属していそうで属していないディレクティブが 2 つ:

- **`noreuse` は単に文書化されていないのではなく、廃止済み。**
  かつては `Compiler.RC2.Reuse` を無効化していたが、無効化すると
  ほとんどのスモークテストで確実にヒープが壊れた。根本原因は
  ついに診断されなかった -- 全経緯は `KNOWN-BUGS.md` の
  "Retired: `--directive noreuse` no longer exists" 参照。
  `applyReuse` は今や常に無条件で実行される。今日 `--directive
  noreuse` を渡しても、他の認識されないディレクティブ文字列と
  同じく無害な no-op。
- **`nomain` は実在する、現在サポートされているディレクティブだが、
  パイプライン段階の無効化ではない。** これは `compileExpr` 内で
  独自の素の `Bool` として直接読まれ、`toRCDefs`/`disabled` を
  一切通らず、`Compiler.RC2.Emit` の `footer` が C の `main()` を
  出力するかどうかだけを制御する -- 下記の第 5 節、および
  `doc/export-support.md` の "Linking as a library" 節にある、
  これが存在する理由のエンドツーエンドのシナリオ(`%export` した
  プログラムを、自前の `main` を供給する手書きの C ドライバへ
  リンクする)を参照。その生成された `main()` はランタイム
  ライフサイクルフックが呼ばれる場所でもあるので、`nomain`
  ドライバは自分で `idris2rc2_rtInit()` / `idris2rc2_rtFinish()`
  を呼ばなければならない -- `doc/runtime-lifecycle.md` 参照。

## 3. デバッグダンプ・ディレクティブ

3 つとも `directiveList` を共有し、`toRCDefs` が既に結果を生成した
*後で*照合される(第 2 節の段階無効化とは異なり、そちらは
`toRCDefs` 自身が実行前に参照する必要がある)。

- **`dumprcexpr`** -- 最終的な `RCExp` を、無効化されていない全
  パイプライン段階の後で、`.c` 出力の隣の `.rcexpr` ファイルへ
  ダンプする。完全なフォーマットリファレンスと読み方は
  `doc/reading-the-ir.md` 参照。
- **`dumpdualabi`** -- `Compiler.RC2.DualABI` 自身の Stage 2 適格性
  解析を `.dualabi` ファイルへダンプする。`dumprcexpr` と同じ
  ディレクティブ機構。`doc/dual-abi.md` 参照。
- **`dumpcc`** -- 実行しようとしている正確な C コンパイル/リンク
  コマンドを stdout へ表示する。

## 4. コード注入ディレクティブ

2 つのディレクティブが、任意の C を生成された `.c` へ、その `#include`
群の直後・生成された定義の前(`Compiler.RC2.Emit` の `header`)へ
そのまま差し込む -- 注入されたコードは rc2 自身のランタイム型
(`IDRIS2RC2_Value` など)を使え、その下の生成された関数本体から
呼び出せる:

```idris2
%cg rc2 extraRuntime=path/to/helpers.c
%cg rc2 inlineRuntime=int64_t helper(int64_t x) { return x * 2; };
```

- **`extraRuntime=<path>`** はファイル全体を読み、その内容をそのまま
  差し込む -- Chez バックエンドが `%cg chez extraRuntime=file.ss` で
  既に使っているのと同じ汎用ディレクティブ(かつ同じ
  `Compiler.Common.getExtraRuntime`)。
- **`inlineRuntime=<code>`** は rc2 独自の、ファイルの代わりに
  テキストを渡す相棒(本家に相当物なし)。

### `inlineRuntime` の 2 つの地雷

どちらも Idris2 自身の汎用 `%cg` レキサ/パーサに固有のもので、
idris2-src に触れずには直せず、特定のディレクティブ値に固有でも
ない -- 十分に複数行/波括弧終わりな `%cg` ディレクティブテキスト
なら、rc2 定義かどうかに関わらず噛みつく。

1. **1 行に収めなければならない。** `%cg name { ... }` の波括弧形式は
   ネストのサポート無しで*最初の*リテラル `}` で止まるので、実際の
   C 関数本体(1 つ持っている)は黙って切り詰められてしまう。
   代わりにコードを `inlineRuntime=` の直後(`{` ではなく)に書くと
   レキサのもう一方の、波括弧なしのフォールバックに当たり、それは
   波括弧の釣り合わせを一切せず行の残りをそのまま消費する -- ただし
   全て 1 行にある場合に限る。
2. **リテラル `}` で終わってはならない。** `Idris.Parser` 自身の
   `stripBraces` は、どのレキサ形式が生成したものであれ、*任意*の
   `%cg` ディレクティブの捕捉テキストから末尾の `}` を 1 つ(と
   先頭の `{` を 1 つ)無条件に剥がす -- 実際の関数本体自身の閉じ
   波括弧を、波括弧形式の区切り文字と区別できない。C 関数定義は
   常に `}` で終わるので、これは黙ってそれを食べてしまい、
   結果として壊れた C は、真の原因から遠く離れた gcc の段階で、
   ずっと後になって初めて失敗する。関数自身の `}` の後の末尾 `;`
   (無害な空のトップレベル C 宣言)がこれを回避する。その `;` が
   代わりに新しい最終文字になるからである。1 行のスニペットより
   長い/厄介なものには、代わりに `extraRuntime=` と実際のファイルを
   使うこと。

### 自然な組み合わせ: 素の `%foreign "C:funcName"`

どちらのディレクティブにも自然な組み合わせは、*素の*
`%foreign "C:funcName"` 宣言 -- lib/header フィールドを一切持たない --
で、注入されたコードへ、1 つの生成された翻訳単位内の単純なテキスト
順序で直接呼び込む。これは別個の静的ライブラリの構築や
`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` の配線を丸ごと省く。対照的に
`libs/rc2base` 自身の README は、その C ヘルパが実際の別個の `.a`
に住んでいるので、それら全てを必要とする。

## 5. 実際にディレクティブを使う

- `idris2-rc2` コマンドラインへ直接: `--directive VALUE`、繰り返し
  可能(第 1 節の例参照)。
- `rc2/tests/verify.sh` 自身の `--directive VALUE` フラグ経由、
  繰り返し可能、`idris2-rc2` へそのまま転送される -- テスト中に
  回帰を特定の 1 パスへ切り分ける標準的な方法、例えば
  `--directive noloop` や `--directive noconstfold` を、実行の合間に
  `toRCDefs` を手で編集して再ビルドすることなく。

## 6. 動機となったスモークテスト

`rc2/tests/Test31CgExtraRuntime.idr`(`extraRuntime=`)と
`rc2/tests/Test32CgInlineRuntime.idr`(`inlineRuntime=`)が第 4 節の
ディレクティブ専用の回帰テスト。どちらも `verify.sh` の
`NO_REFC_DIFF_TESTS` に載っている。本家 RefC は `--directive`/`%cg`
を一切何にも読まないので、乖離する共有ベースライン挙動が無く、
`verify.sh` が行う意味のある RefC 比較も無いためである。

## ファイル

- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs` 自身の段階無効化の
  配線、`compileExpr` 自身の `directiveList` 取得とそこから読まれる
  全ディレクティブ、`getInlineRuntime`。
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `InjectedRuntime`、2 つの
  コード注入ディレクティブが書き込むヘッダスコープの状態。
- `rc2/tests/Test31CgExtraRuntime/`、`rc2/tests/Test32CgInlineRuntime/`
  -- 動機となったスモークテスト(第 6 節)。
- `KNOWN-BUGS.md` -- `noreuse` の廃止経緯。
