# セルフホスティング: Chez Schemeを使わずにコンパイラをビルドする

(原文: `doc/self-hosting.md`。内容が乖離した場合は原文を正とする。)

状態: ステージ1と2は実験として済んでいる(`idris2-rc2-norepl`をrc2でビルドし、それがライブラリをビルドし、コンパイラのAPIパッケージを型検査し、自分自身をビルドする。そのすべてで、Chezでビルドしたコンパイラと同じ結果になる)。`rc2/tests`の81個のプログラムでは、浮動小数点リテラルの表記(発見事項9)を除いて、Chezでビルドしたコンパイラと同じCを出力する。シード、`--install`、速度は未解決である。この文書は、分かったことと、残りの設計を記録する。

コマンド: `rc2/tests/selfhost.sh`(「再現手順」を参照)。これを可能にするドライバは`norepl.md`で説明している。

## 「Chezを使わない」の意味

現在のツールチェーンは次のようにビルドされる。

```
nixpkgs idris2 (Chez)  ->  idris2 (Chez)   builds   prelude, base, ..., idris2api, rc2, rc2base ...
```

ユーザーが実行するコンパイラ`idris2-rc2`は、それ自体がChezのプログラムである。上流の`idris2`ライブラリ(`idris2api`)はChezでコンパイルされ、`idris2 --build rc2.ipkg`はそれをリンクするためにChezを実行する。目標は、シードの後はChez Schemeを一切必要としないツールチェーンである。コンパイラはrc2が作るCのプログラムであり、それが必要とするもの(ライブラリの`.ttc`ファイル、ランタイム)はすべて、そのコンパイラかCコンパイラが作る。

## Chezが使われていた場所

1. **コンパイラの実行ファイル。** `idris2-rc2`は、Chez用の`idris2.so`である。
2. **`.ttc`ファイル。** `prelude`、`base`、`linear`、`network`、`contrib`、`test`、コンパイラのAPIパッケージ(`idris2api`)、`rc2`、`rc2base`などのものである。これらはChezでビルドした`idris2`が書き出す。
3. **Chezを呼ぶコンパイラ内のコード。** REPLのScheme評価器(`Core.SchemeEval`。`Libraries.Utils.Scheme`にある29個の`%foreign "scheme:..."`宣言を通じて呼ぶ)である。`idris2api`やライブラリのほかの部分は、ビルドにChezを必要としなかった。`Libraries.Data.String.Iterator`などには`RefC:`の実装があり、rc2はそれを使う。
4. **最初のコンパイラ**(nixpkgsの`idris2`)。1回だけ使う。

Chezではないもの: `libidris2_support`(C。`idris2-src/support/c`から)とrc2のランタイム。

## 分かったこと

1. **REPLがChezをバイナリに引き込む。** `Idris.Package.processPackage`(`--build`、`--install`など)は、privateな`runRepl`を通じて`repl`に到達する。REPLは`process`に到達し、その`Scheme`評価モードが`Core.SchemeEval`である。コマンドラインからREPLに至る経路を閉じても(`NoRepl.Driver`)、REPLはバイナリから消えなかった。そのため、Chez専用の宣言はまだリンクされている。
2. **`%foreign_impl`でそれらを置き換えられる。** privateな名前(`prim_isNumber`など)にも使える。`NoRepl.SchemeStubs`は、29個の宣言に、プログラムを停止させる本体を与える。バッチのコンパイルはこれらを呼ばない。(`Idris.ProcessIdr`の`prim__gc`、つまり`scheme:collect`には何も要らなかった。到達しないからである。)
3. **rc2は、それらの宣言の型である`ForeignObj`(`CFForeignObj`)を知らなかった。** 現在は`CFUser`と同じように素通しする。
4. **`rc2.ipkg`に3つのモジュールが載っていなかった**(`Compiler.RC2.Types`、`Sink`、`DeadVars`)。そのため`idris2 --install`は不完全な`rc2`パッケージをインストールしていた。`depends = rc2`が動いたのは、`build/`に残りがある`rc2/`の中だけだった。現在は載せてある。
5. **Chezでビルドしたコンパイラとrc2でビルドしたコンパイラは一致する。**
   - `prelude`(14ファイル)、`base`(136)、`linear`(14)、`network`(5)、`contrib`(103)、`test`(1)、`idris2api`(292)の`.ttc`は、同じオプションでビルドすると、565個のうち565個がバイト単位で一致する。(インストール済みのものとの比較は意味がない。インストール済みのものは`IDRIS2_INC_CGS`付きでビルドされており、1つも一致しない。)
   - `Hello`、`Test149StrLiteralFold`、`Test87SpecConstCon`のCは一致する。`Test112Numeric`は2行だけ異なる。`Double`のリテラルを、rc2のランタイムは`4611686018427388000.0`と、Chezは`4.611686018427388e18`と表示する。値は同じである。
   - **不動点**: 自分自身でビルドした`idris2-rc2-norepl`は、同じ114 MBのCファイルをバイト単位で同じに出力する。これが示すのは、その入力について2つのコンパイラが一致することである。すべてのプログラムで一致することは示さない(発見事項9は、さらに多くを比較して見つかった)。
6. **ビルドのサイズと時間。** `idris2-rc2-norepl`のCは114 MB(169万行。gzipで9.3 MB、xzで5.8 MB)、実行ファイルは15 MBである。Chezでビルドしたrc2がCを出力するのに75秒かかり、Cコンパイラ(`-O2`)はさらに1コアで約9分かかる。
7. **大きなビルドでは、rc2でビルドしたコンパイラは、Chezでビルドしたものより時間で約1.7倍遅い**(`base`で1.65。短い`prelude`のビルドで1.35)。実行する命令数は約2.1倍である。

   | 作業 | Chezでビルド | rc2でビルド | 比 |
   |---|---|---|---|
   | `base`(136モジュール)、2026-11 | 52.4 s | 86.7 s | 1.65 |
   | `base`、型検査のみ(`Elaborating`の時間) | 44.3 s | 74.3 s | 1.68 |
   | `prelude` | 5.1 s | 6.9 s | 1.35 |
   | `contrib`(103)、以前 | 29.5 s | 62.9 s | 2.1 |
   | `linear`、`network`、`test`、以前 | 6.7 s | 10.3 s | 1.5 |
   | `idris2api`の型検査(292)、以前 | 403 s | 894 s | 2.2 |
   | `libs/control-async`の型検査(11)、以前 | 4.9 s | 8.2 s | 1.7 |

   「以前」と記した行は、下に挙げる高速化より前の計測である(古い`base`の行は109.9 s、比2.1だった)。`idris2api`の行は、同じマシンで別のビルドと並行して走らせた。そのほかは単独で、各1回の計測である。小さなプログラムのコンパイルは、どちらでもほぼ同じ時間がかかる(その大部分はCコンパイラである)。

   - **飛び抜けたモジュールはない。** `base`の136モジュールで、`Elaborating`の時間の比は1.6から2.1の間にある(Chezでビルドしたコンパイラで0.5秒を超える20モジュールの中央値は1.69)。ほとんど何もしないモジュールは0.08秒対0.05秒で、比は同じである。
   - **`prelude`の比が良く見えうる理由。** 3行のモジュール1つの検査で、Chezでビルドしたコンパイラは3.44 G命令、rc2でビルドしたものは2.38 G命令を実行する(callgrind)。Chezでビルドしたコンパイラのこの固定コストは、`prelude`のビルドのような短い実行では大きな割合を占め、比が良いことの一部を説明しうる。これ以上は計測していない。
   - **rc2でビルドしたコンパイラで、小さな検査の時間がどこに行くか。** その2.38 G命令の64%は、`prelude`の`.ttc`の読み込み(`readFromTTC`、`fromBuf`)である。この処理は小さなオブジェクトを多数作る。
   - **型検査以外。** `base`のビルドで、rc2でビルドしたコンパイラでは時間の14%(86.7秒のうち12.4秒)、Chezでビルドしたものでは15%(52.4秒のうち8.1秒)である。

   `leaf-tail-calls.md`のコンポーネント規則(葉の規則を置き換えたもの)を使うと、rc2でビルドしたコンパイラで`libs/prelude`をビルドしたときの命令数は、39.14 Gから36.94 Gになる。Chezでビルドしたものは17.28 G(callgrind)なので、命令数は約2.1倍である。`idris2-rc2-norepl`のビルド(`rc2-norepl.ipkg`、Cのコンパイルを含む)は、Chezでビルドしたコンパイラで10分3秒、rc2でビルドしたもので12分18秒かかる(各1回)。このビルドのcallgrindのプロファイルでは、`malloc`/`free`が命令の27%、参照カウント(`dup`、`drop`、`teardown`)が26%、確保のラッパーが8%を占め、メモリ管理が合わせて約60%になる。上位は`idris2rc2_teardown` 8.9%、`idris2rc2_drop` 8.8%、`free` 8.3%、`malloc` 7.1%、`idris2rc2_dup` 6.8%である。コンパイラ自身の関数で1.4%を超えるものはない。

   このビルドを速くするために試したことと、その効果(セルに断りがなければ、rc2でビルドしたコンパイラで`libs/prelude`をビルドして計測):

   | 変更 | 命令数 | 時間 | 採用 |
   |---|---|---|---|
   | 循環のない呼び出し先の集合から出る末尾呼び出しを直接呼び出しにする(`leaf-tail-calls.md`) | -5.6% | Chezでビルドしたコンパイラによる`rc2-norepl`のビルドで-7% | する |
   | `let x = <constant>`とその`dup`/`drop`を除く(`dead-vars.md`) | -0.004% | | する(IRが小さくなる) |
   | 条件式の作業用の`int cmp_N` / `int64_t tmp_N`を除く | 未計測(`gcc`が畳み込むはず) | | する(Cが4,041行減る) |
   | `mimalloc`をプリロードする | | -13%(`prelude`)、-12%(`base`) | しない(依存が増える) |
   | 同じサイズの別のコンストラクタにコンストラクタのセルを再利用する | -0.45% | | しない(効果が小さすぎる) |
   | `dup`/`drop`の高速経路を強制的にインライン化する(`always_inline`) | -7.1% | -5% | しない(`rc2-norepl`のビルドが10分から40分に、実行ファイルが15 MBから38 MBになる) |
   | `dup`/`drop`のNULL/即値の判定だけをインライン化する | +3.4% | +8% | しない(遅くなる) |

   借用されるだけのコンストラクタをスタックに確保しても、届くものは少ない。実行時ではなく、コンパイラのIR上で静的に数えると、`let`で束縛される34,383個のコンストラクタのうち、末尾でない呼び出しのすべての引数を借用できるとしても、スタックに確保できるのは最大7.6%である。現在借用できるパラメータ(`borrow-inference.md`)では1.4%である。`teardown`は、解放するオブジェクト1個あたり約47命令かかる(1回の呼び出しで構造全体を解放するので、コストはオブジェクトの数に比例する)。未解決の項目は`TODO.md`(「a small-object allocator」)にある。

   セルフビルドは実験であり、Chezでビルドしたコンパイラの代わりではない。
8. **rc2でビルドしたコンパイラで動くもの**(テスト済み): `-o`、`--check`、`--typecheck`、パッケージ(ライブラリと実行ファイル)の`--build`、`--version`、`--help`。`--exec`は、Chezでビルドした`idris2-rc2-norepl`でしか実行していない。**未テスト**: `--install`、`--mkdoc`、`--clean`、`--incremental`。

9. **rc2でビルドしたコンパイラは、String定数をNULで切っていた(修正済み)。** `rc2/tests`の81個のプログラムを両方のコンパイラでコンパイルし、Cを比較して見つけた(最初は77個が一致。修正後は78個が一致し、3個が浮動小数点の表記だけで異なり、それ以外の違いはない。「再現手順」の`diff`を参照)。
   - `Test112Numeric`、`Test168NumericEdge/DoubleString`、`Test168NumericEdge/DoubleToIntWrap`は、`Double`リテラルの表記(と、それから作る定数の名前)だけが異なる。`1e-6`と`0.000001`、`9.007199254740992e15`と`9007199254740992.0`である。値は同じである(19個のリテラルを浮動小数点のパーサで確認した)。
   - `Test169Strings/StringNul`は1190行異なる。`"ab\x00""1cd"`が`"ab"`になっていた。最小の例: `printLn (Prelude.String.length "ab\NUL1cd")`は、Chezでビルドしたコンパイラでコンパイルすると6を、rc2でビルドしたものでは2を表示する。
   - 原因: `Data.Buffer.stringByteLength`、`prim__setString`、`prim__getString`は`char *`を扱う`RefC:`のforeignであり、rc2はこれらを`fastPack`などと違って差し替えていなかった。そして、コンパイラの`.ttc`のコード(`TTC String`、`Core.Binary.Prims`)は、まさにこの3つを使う。エラボレーションと正規化器は正しい(`length "ab\NUL1cd" = 6`は両方のコンパイラで受理される)。文字列は、エラボレーションとコード生成の間で失われる。(`Core.Hash`だけが使う`Libraries.Data.String.Iterator`も、差し替えていなかった`char *`の例だった。)
   - Chezでビルドしたコンパイラにも、ここにバグがある。非正規化数の`5e-324`を`5e-324|1`(Chezの表記)と出力するが、これはCではない。rc2でビルドしたものは正しい。
   - 修正: プログラムを`RCDef`に変換するときに、`Data.Buffer`の3つの関数(と`Libraries.Data.String.Iterator`)を、長さを扱えるrc2独自のものに置き換える(`Compiler/RC2/ForeignDivert.idr`)。何をなぜ置き換えるかは、`fastpack-fix.md`の「What is replaced, and why」にある。`Test169Strings/StringNul`がこれを確認する。

## 設計

### 連鎖

```
seed        ->  stage1                 ->  stage2 (the proof)
(C or Chez)     idris2-rc2-norepl          stage1 builds libs + idris2api + itself;
                built by rc2               its C must equal the C of stage1
```

- **stage1**は、rc2が`rc2-norepl.ipkg`からビルドした`idris2-rc2-norepl`である。`rc2`とその依存の`.ttc`が必要なので、最初はシードのツールチェーンから持ってくる。
- **libs**: stage1が`prelude`、`base`、`linear`、`network`、`contrib`、`test`をビルドし(順序と`IDRIS2_PATH`は`idris2-src/Makefile`に従う)、次にAPIパッケージ、`rc2`、`rc2base`をビルドする。これらが新しいプレフィックスに揃えば、古いツールチェーンは要らない。
- **不動点**: stage1が`rc2-norepl.ipkg`をビルドする。そのCファイルはstage1のものと一致しなければならない。これが、ツールチェーンが自分自身を再現することの確認である。

### シード

最初のstage1を得る方法は3つある。望ましい順に挙げる。

1. **stage1のCファイル**をリリースに同梱する(xzで5.8 MB。gitには入れない)。Cコンパイラ、`libidris2_support`、rc2のランタイムがあれば、コンパイラを作れる。不動点の確認で、シードが現在のソースから得られるCであるかが分かる。
2. **Chez**(`selfhost.sh stage1`が行うこと): `idris2 --build rc2.ipkg`の後、rc2が`rc2-norepl.ipkg`をビルドする。ソースから始める方法として残る。
3. **nixpkgsの`idris2`**: 現在のビルドの最初のステップ(README)。

### ツールチェーンに含まれるもの

目標は`install/idris2-0.8.0/`である。ライブラリとAPIパッケージの`.ttc`、`support/`(Cのサポートライブラリとrc2のランタイム)、`rc2`、`rc2base`などのパッケージ、そして`bin/idris2-rc2-norepl`を含む。`.ttc`がstage1から来るようになれば、この中にChezを必要とするものはないはずである。ビルドにもインストールにも、上流の`idris2`(REPLを持ち、Chezでビルドしたもの)はもう要らなくなる。このようなプレフィックスは、まだ誰も作っていない。`--install`が最初の未解決の項目である。

## 未解決の項目(取り組む順)

1. **stage1での`--install`とほかのパッケージコマンド。** これらはプレフィックス(`.ttc`、`.ttm`、`postinstall`のサポートファイル)を書き出す。テスト: stage1だけでプレフィックスをビルドし、それを使って`rc2/tests/verify.sh`と`libs/*`のverifyスクリプトを走らせる。
2. **シードのリリース**(Cファイル、その作り方と確認方法)と、stage1があるときにChezを要求しない`gen-env.sh`/`env.sh`の判定。
3. **速度。** 時間で約1.7倍、命令数で2.1倍(発見事項7)。これが下げるべき数値である(目標: 1.2以下)。プロファイルは取ってある。命令の約60%がメモリ管理で、飛び抜けた関数はない。残る手は、その処理を減らすこと(発見事項7の表に試したことがある)か、1回の操作を安くすること(`TODO.md`の「a small-object allocator」)である。コンパイラは、rc2の最適化にとって最良の大規模プログラムでもある。
4. **ビルド時間。** 1コアでCコンパイラに9分かかる。モジュールごとのC(`--inc rc2`)や、複数の翻訳単位に分割したCファイルにすれば、`make -j`が効く。もう1つの手は、コールドなコードを`-O1`にすることである。
5. **REPLをバイナリから除く**(上記には不要): `processPackage`のコピー、つまり`Idris/Package.idr`の約1100行が要る。
6. **上流への追従**: `NoRepl.Driver`と`SchemeStubs`は、上流のコードをコピーし、スタブにしている。コピーした関数を新しい上流のソースと比べるスクリプトと、スタブのない`scheme:`宣言を列挙するスクリプトを、`idris2-src`を更新したときに走らせるべきである。

## セルフビルドしたコンパイラのプロファイル(2026-11-04)

`-O2`でセルフビルドした`idris2-rc2`で、作業用のコピーの中で`rc2.ipkg`をビルドし(`IDRIS2_CC=true --cg rc2 --build rc2.ipkg`。そのためCコンパイラは走らない)、`perf record -e cpu-clock`で計測した(ユーザー空間のみ。`perf_event_paranoid`が2なので、カーネルのサンプルはない)。`perf`は`nix-shell -p perf`で用意した。生成したCはフレームポインタなしでビルドされるので、コールグラフには`--call-graph dwarf,12288`が要る。これは深いスタックを途中で切るので、葉の関数の呼び出し元についての情報は一部が欠ける。

`perf`なしの時間(`.ttc`はビルド済みなので、コード生成だけ): セルフビルドしたコンパイラで2分47秒、Chezでビルドしたもので1分20秒。セルフビルドしたコンパイラでの最初からのビルド(型検査とコード生成)は4分35秒である。

型検査だけ(`--typecheck rc2.ipkg`、109秒、フラットなプロファイル)では、メモリ管理がサンプルの約56%を占める。`idris2rc2_teardown` 10%、`dup` 8%、`drop` 7%、`malloc`と`free`で15%、glibcの内部関数(`_int_malloc`、チャンクの関数)12%、`newConstructor`と`alloc`で4%である。包括時間(dwarfのコールグラフ)では次のとおりである。
- `TTImp.Elab.Check.check` 27%、`checkApp` 22%、`tryError`/`handle` 13-23%、`solveConstraints` 11%、`AutoSearch.searchType` 12%、`readModule` 13%。
- `Core.Directory.nsToPath` 8.2%(`Libraries.Utils.Path.parse` 8%)と`Compiler.Inline.compileAndInlineAll` 12.7%。rc2が変更しない、上流のIdris2の関数である。
- `Name.compare`、`UserName.compare`、`memcmp`、`NameMap.lookup`が合わせて5-9%。`dup`の呼び出し元には`Name.compare`(サンプルの3.8%)があり、これは両方の名前のフィールドを`dup`する。

コード生成を`--timing 2`で、セルフビルドしたコンパイラとChezでビルドしたもので比べる。

| パス | セルフビルド | Chezでビルド |
|---|---|---|
| early inline | 167 sのうち68.4 s | 80.5 sのうち31.8 s |
| late inline | 10.9 s | 5.2 s |
| speculative specialization | 9.5 s | 4.2 s |
| DualABI | 7.6 s | 3.6 s |
| RC annotate + Reuse + ConAltNative | 5.5 s | 未計測 |
| function dedup | 4.2 s | 1.5 s |

各パスは2.1倍から2.3倍遅く、function dedupは2.8倍である。どちらでも、early inlineが実行全体の約40%を占める。`--timing 3`(Chezでビルドしたもの)では、early inlineの外側の反復が9回あり、ラウンドの合計が23.5秒になる。early inlineとlate inlineを通して、`LI prune`が28ラウンドで8.0秒、`LI analyse`が29ラウンドで5.3秒、`LI defOf`が0.9秒かかる。1ラウンドで差し込む関数がどれほど少なくても、平均で1ラウンドあたり約0.5秒である(最初の2ラウンドは何もない状態から始まるので重い)。`TODO.md`(「Compile time: refactoring ideas, 2026-09-29」)には、解析はすでに前のラウンドから再開していること(`inlining.md`の「Rounds are incremental」)と、刈り込みのインクリメンタル化は、idris2-lspで0.3秒という見積もりのもとで、その複雑さと比べて見送ったことが記録されている。上の合計は別のプログラムについてのもので、2つのインラインの段階の両方を含む。この判断は変わらない。

コード生成では、`Prelude.Types.List.reverseOnto`がサンプルの3.8%を占める。(途中で切れた)コールグラフでは、その呼び出し元は`tailRecAppend`と`RC2.lowerProgram`である。

## 再現手順

```sh
cd rc2
./tests/selfhost.sh stage1   # about 10 minutes
./tests/selfhost.sh libs     # 3 to 4 minutes
./tests/selfhost.sh api      # about 15 minutes
./tests/selfhost.sh fixed    # about 12 minutes
./tests/selfhost.sh diff     # about 10 minutes: compiles rc2/tests with both compilers
```

`diff`には、Chezでビルドした`idris2-rc2`(`stage1`のステップ1で作られる)と`stage1`が必要である。浮動小数点の表記以外でCが異なるプログラムを列挙し、1つでもあれば失敗する。

`stage1`が書き出すもの(`idris2 --install rc2.ipkg`が`install/`の`rc2`パッケージを更新し、`rc2/build/exec`に新しい実行ファイルが入る)を除いて、すべては`rc2/build/selfhost`(gitの管理外)の下にビルドされる。「分かったこと」にある、Chezでビルドしたコンパイラとの比較は、Chezでビルドした`idris2-rc2-norepl`(`idris2 --build rc2-norepl.ipkg`)で同じコマンドを別のディレクトリで実行し、`.ttc`を`cmp`で比べて行った。
