# `idris2-rc2-norepl`: REPLを持たないドライバと、rc2によるコンパイラのビルド

(原文: `doc/norepl.md`。内容が乖離した場合は原文を正とする。)

`rc2-norepl.ipkg`は、`idris2-rc2`の隣に2つ目の実行ファイル`idris2-rc2-norepl`をビルドする。コンパイラとしては同じもの(`Compiler.RC2.*`はインストール済みの`rc2`パッケージから来る)で、ドライバにREPLがない。これは1つの問いに答えるために作った。コンパイラ自身を、Chez Schemeを使わずにrc2でビルドできるか、という問いである。答えはイエスである(「結果」を参照)。`idris2-rc2`には手を加えていない。rc2への変更は、「必要だったこと」の項目3と、`rc2.ipkg`のモジュールリスト(3つのモジュールが抜けていた)である。これが何のためのものか、これで何が見つかったかは`self-hosting.md`にある。

## 構成

```
rc2/rc2-norepl.ipkg          sourcedir = "src_norepl", depends rc2
rc2/src_norepl/NoRepl/Main.idr          main = mainNoRepl [("rc2", codegenRC2)]
rc2/src_norepl/NoRepl/Driver.idr        the driver (copied from Idris.Driver, see below)
rc2/src_norepl/NoRepl/SchemeStubs.idr   %foreign_impl stubs for Libraries.Utils.Scheme
```

モジュール名を`NoRepl.*`にしたのは、upstreamの`Idris.Driver`や`rc2.ipkg`の`Main`と取り違えないようにするためである。

## upstreamから持ってきたもの

`NoRepl.Driver`は、`idris2-src/src/Idris/Driver.idr`から`findInputs`、`splitPaths`、`updateEnv`、`ignoreMissingIpkg`、`checkVerbose`、`stMain`、`quitOpts`、`mainWithCodegens`(`mainNoRepl`として)をコピーし、`Idris/SetOptions.idr`から`postOptions`(`postOptionsNoRepl`として)をコピーしている。省いたものは次のとおりである。

- バナー、`updateREPLOpts`(エディタ)、最後の`repl` / `replIDE`の呼び出し。オプションを実行した後、プログラムはREPLがないことを表示して、終了ステータス1で終了する。
- `--yaffle`、`--ttm`、`--ide-mode`、`--ide-mode-socket`、`--repl [package]`、`--client <cmd>`。どれもメッセージを出して拒否する。
- `postOptions`の`replCmd`の分岐。

upstreamのソースを更新したときは、これらの関数をコピーと比較すること。

## ビルド

```sh
cd rc2
source ../env.sh
idris2 --build rc2.ipkg && idris2 --install rc2.ipkg      # the rc2 package first
idris2 --build rc2-norepl.ipkg                              # with Chez, as usual
./tests/norepl-smoke.sh                                     # checks that build
```

rc2自身でビルドする場合(Chezを使わずにビルドしたコンパイラ):

```sh
build/exec/idris2-rc2 --cg rc2 --build rc2-norepl.ipkg      # about 10 minutes
```

## 必要だったこと

1. `Idris.Package.processPackage`(`--build`、`--install`、...)は、privateな`runRepl`を通じて`repl`に到達しうる。そのため、REPLは依然としてリンクされる。それに伴って、REPLの`Scheme`評価モード(`Core.SchemeEval`)もリンクされる。これは`Libraries.Utils.Scheme`の`%foreign "scheme:..."`宣言を通じてChezを呼ぶ。`Package.idr`(約1100行)をコピーするほどの価値はなかった。
2. そこで`NoRepl.SchemeStubs`は、それら29個の宣言それぞれに、プログラムを停止する(`abort()`)本体を持つ`%foreign_impl`を与える。バッチコンパイルでこれらを呼ぶものはない。呼べばバグであり、それははっきり表に出る。
3. rc2はforeign型`ForeignObj`(`CFForeignObj`)を知らなかった。現在は`CFUser`と同じように素通しする(`Emit/Util.idr`、`Emit/Foreign.idr`)。

## 結果

- rc2は`idris2-rc2-norepl`を自身でビルドできる。コード生成に約75s、114 MBのCファイルに対するCコンパイラにさらに9分かかる。実行ファイルは15 MBである。
- rc2でビルドしたコンパイラはプログラムをコンパイルでき、Chezでビルドしたものと同じCを出力する(違いは1つで、`Double`リテラルをrc2のランタイムが表示することである。`self-hosting.md`を参照)。ライブラリとコンパイラのAPIパッケージを、Chezでビルドしたコンパイラと同一の`.ttc`ファイルでビルドでき、自分自身も同じCでビルドできる。つまり不動点に達する。`base`のような大きなビルドでは、約1.7倍遅い(`self-hosting.md`、知見7)。
- 実行ファイルを持つipkgの`--build`と、`--typecheck`は動作する。

## 未対応のこと

- REPLはバイナリから取り除かれていない。コマンドラインからそこへ至る経路を閉じただけである。取り除くには`processPackage`のコピーが必要になる。
- rc2でビルドしたコンパイラでの`--install`は試していない。Chezを使わないツールチェーンへの残りの道のりは`self-hosting.md`にある。
