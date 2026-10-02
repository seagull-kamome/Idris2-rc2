# idris2-rc-cg

*[English](README.md)*

このリポジトリは、[Idris2](https://github.com/idris-lang/Idris2)用の独立した外部Cコード生成バックエンド**rc2**の作業リポジトリである。
上流のIdris2は、参照用にチェックアウトして横に置くだけで、手は加えない。

## 構成

```
.
├── env.sh          生成された環境設定（rc2のビルド・実行前にsourceする）（gitignore対象）
├── gen-env.sh       env.shを再生成する。自前ビルドのinstall/binコンパイラを指すPATHと、そのサポートライブラリのパスを設定する（Chez Schemeが`scheme`という名前でPATHにある必要がある）
├── idris2-src/      github.com/idris-lang/Idris2のクローン。参照用であり、自前ビルドidris2のソースでもある（gitignore対象、無変更）
├── install/         自前ビルドのidris2ツールチェーンと、rc2パッケージ・ランタイムのローカルインストール先（gitignore対象、ビルド成果物）
├── libs/rc2base/    付属のサポートライブラリパッケージ（下記libs/rc2base/を参照）
├── libs/text-re2/   RE2正規表現バインディングの兄弟パッケージ。rc2baseから分離した（下記libs/text-re2/を参照）
├── libs/iouring/    io_uringバインディング（System.IO.Uring）（libs/iouring/README.mdを参照）
├── libs/notcurses/  notcursesバインディング（System.Notcurses）、rc2専用（libs/notcurses/README.mdを参照）
├── tools/           rc2自身の出力を読む単体ツール（下記tools/rcexpr-lint/とtools/rcexpr-diff/を参照）
└── rc2/             本体の成果物（下記rc2/を参照）
```

`idris2-src`と`install`はgitの管理対象外である。
`idris2-src`は、`git clone https://github.com/idris-lang/Idris2.git idris2-src`でいつでも取得し直せるもので、編集はしない。
このクローンは参照資料として使う（生成されたCの比較、preludeの`%foreign`宣言の確認、回帰テストの借用や移植）。
同時に、自前ビルドの`install/bin/idris2`をブートストラップするためのソースでもある。
nixpkgsの`idris2`は、このブートストラップにだけ使う。
`install`は、ブートストラップと`rc2/`のビルドによって再生成される。

クローンしたら、最初に一度`gen-env.sh`を実行して`env.sh`を生成しておく。

### `rc2/`

```
rc2/
├── rc2.ipkg           Idris2パッケージ。実行ファイルidris2-rc2をビルドする
├── src/Compiler/RC2/
│   ├── RCExp.idr        IR。ANF正規化され、所有権の注釈が付いた式
│   ├── Util.idr         2つ以上のパスが共有する、依存の少ない小さなヘルパー（依存の末端に位置し、importは循環しない）
│   ├── RC.idr           case tree -> RCExp。Phase 1でラムダリフティングと正規化、Phase 2でannotate（dup/drop/freeの挿入）
│   ├── Types.idr        native/boxed表現の推論（Rep）
│   ├── InlineCExp.idr   リフティング前のcase treeに対する、プログラム全体のインライン化。呼び出しを含まない小さな関数はすべての呼び出し箇所で、ループを含まない関数は唯一の呼び出し箇所で展開する
│   ├── LateInline.idr   ループ変換後のRCExpに対する、プログラム全体のインライン化。呼び出し箇所が1つだけの関数が対象
│   ├── ArityRaiseCExp.idr, ArityRaise.idr
│   │                    world引数のarity raising。worldを待つクロージャを返す関数が、world自体を引数に取るようにする
│   ├── DeadArgs.idr     フロントエンドが`where`関数に渡す未使用の引数を取り除く
│   ├── LazyCaf.idr      トップレベルの`Delay`を、lazyセルではなく通常の（メモ化された）CAFにする
│   ├── LazyFold.idr     ちょうど1回だけforceされるローカルなlazy値を、直接の呼び出しにする
│   ├── ConstFold.idr    ExtPrim（prim__codegen）、算術、比較、キャスト、定数に対するcaseを畳み込む。エスケープしないコンストラクタと部分適用も畳み込む
│   ├── PushCon.idr      `case`を、マッチ対象の値の末尾へ押し込み、末尾のコンストラクタを畳み込めるようにする
│   ├── SpecClosure.idr  定数クロージャや定数コンストラクタ（インターフェース辞書）が引数に渡されるたびに、呼び出し先を複製する
│   ├── Reuse.idr        コンストラクタのその場再利用
│   ├── ConAltNative.idr 分解したフィールドのうち、nativeとして繰り返し読まれるものをキャッシュする
│   ├── DeadVars.idr     どこからも参照されない分解済みフィールドを空にする
│   ├── MutualLoop.idr   相互末尾再帰 -> 1つに統合した自己末尾再帰関数
│   ├── Trmc.idr         tail recursion modulo constructor -> 各セルの穴を埋めるループ
│   ├── ClosureCtx.idr   差分リスト（`c . (y ::)`）のパラメータを、セルの連鎖として保持する
│   ├── Loop.idr         自己末尾呼び出し -> goto。native shadowの導入と、ループ不変なパラメータ・式の巻き上げ
│   ├── Sink.idr         分岐局所への沈め込み。1つの枝でしか使われないletを、その枝の中へ移す
│   ├── DualABI.idr      関数境界をまたぐ二重（Boxed/native）呼び出し規約、構造体での戻り値
│   ├── DeadCode.idr     プログラム全体のmark-and-sweepによるデッドコード除去（パイプラインのIRレベル最終段）
│   ├── DupMerge.idr     直線的な1つの区間にある、同じ変数に対する複数のRDupノードを、1回のまとめた呼び出しに統合する
│   ├── Emit.idr         RCExp -> Cの出力（機械的な変換。所有権の判断はここでは行わない）
│   ├── Emit/Util.idr        Emit.idrが使うC出力の基本部品（名前のマングリング、リテラルと演算子の
│   │                        出力、Boxed/native値の出力、クロージャ、FFIのCFType対応付け）
│   ├── Emit/Foreign.idr     %foreign / %exportのCラッパー生成と、共有のFFIマーシャリング
│   ├── Emit/ExternRefs.idr  externで参照するシンボルを走査する処理（インクリメンタルコンパイル用の前方宣言）
│   ├── Pretty.idr       人間が読めるRCExpのダンプ（`--directive dumprcexpr`）
│   ├── CC.idr           Cコンパイラの起動とリンク
│   └── RC2.idr          バックエンドのエントリポイントとパイプラインの組み立て（Idris2のコード生成器の振り分けに登録する）
├── support/rc2/       ランタイムライブラリ（libidris2rc2.a）。rc2でコンパイルしたすべてのプログラムにリンクされる
├── doc/               パスごとの詳しい設計ノート（索引はAGENT.mdのLayout節を参照）
└── tests/
    ├── TestNName/TestNName.idr                          手書きのスモークテスト。パスや見つかったバグごとに1ディレクトリ（複数のバグを1つにまとめることもある）
    ├── Bench*.idr                                       上流RefCと比べるベンチマーク
    ├── verify.sh                                        ビルドと回帰テスト全体を一度に実行する（下記「テスト」を参照）
    ├── tsan.sh                                          マルチスレッドのテストをThreadSanitizerで実行する（verify.shから呼ばれる）
    ├── bench.sh                                         ベンチマークを一度に実行する（下記「テスト」を参照）
    ├── snapshot.sh, nopass.sh                           出力を変えないはずの変更を確認する（下記「テスト」を参照）
    └── refc-suite/                                      上流のRefC回帰テストスイートの一部を移植したもの
```

`rc2`は**完全に独立した**Idris2パッケージであり、`idris2-src`には*マージしていない*。
ビルドすると別の実行ファイル`idris2-rc2`ができ、上流の`idris2`バイナリは一切変更しない。
rc2はCを出力対象とし、値の表現、参照カウント、クロージャの仕組みはIdris2自身の`RefC`バックエンドを手本にしている。
その上に、独立していて個別に無効化できる最適化パスのパイプラインを載せている（case tree -> `RCExp` -> Cの順に変換する）。
上流の`Lifted`は使わず、ラムダリフティングは自前で行う（`rc2/doc/lambda-lifting.md`を参照）。
パスの正確な実行順は、`Compiler.RC2.RC2`の`toRCDefs`にある。
主な特徴は次のとおりである。

1. **独立したIRパスとしての参照カウント**。
   RefCは参照カウントの処理をコード生成の途中に織り交ぜるが、rc2はC出力の前に別のパスとして実行する（Perceus/Kokaと同じ方式）。
   `RCExp`には明示的な`RDup`/`RDrop`/`RFree`ノードがあり、`RC.idr`の所有権解析パス（`annotate`）が一度だけ挿入する。
   以降のパスは、この判断に手を触れないか、木の形を変えるときに判断との一貫性を保ったまま更新する。
   `Emit.idr`/`Emit/Util.idr`は、判断が済んだ木を機械的に変換するだけである。
2. **native（unboxed）表現の推論**（`Types.idr`）。
   対象は固定幅の数値の中間値で、後続のパスによって、適用範囲は1つの関数本体を大きく超えて広がる。
   Boxed/nativeの二重呼び出し規約により、native値は通常の呼び出し境界をまたげる（`DualABI`）。
   自己末尾再帰や相互末尾再帰のループでは、ループカウンタをループの全期間にわたってunboxedのnative値のまま保つ（`Loop`/`MutualLoop`）。
   分解したフィールドを繰り返し読む場合は、そのcase分岐の中でnative shadowとしてキャッシュする（`ConAltNative`）。
3. **コンストラクタのその場再利用**（`Reuse.idr`）。
   値を分解してすぐに同じ形の値を組み立て直す`case`では、実行時にその値が一意に所有されていれば、新たに確保せず元の領域をその場で再利用する。
4. **ループ不変式の巻き上げと除去**（`Loop.idr`）。
   反復のあいだ実際には変化しないループパラメータは、ループが持ち回る状態から完全に取り除く。
   ループの先頭で無条件に実行される部分にある不変式は、反復ごとに計算せず、ループの前で一度だけ計算する。
5. **分岐局所への沈め込み**（`Sink.idr`）。
   `let`で束縛した値が、直後の分岐の1つの枝でしか読まれない場合は、その束縛をその枝の中へ移す。
   これはループとは無関係に働き、(4)の鏡像にあたる。(4)は計算を繰り返しから遠ざけるが、こちらは計算を唯一の使用箇所の*近くへ*移す。
6. **プログラム全体のインライン化と定数畳み込み**（`InlineCExp.idr`、`LateInline.idr`、`ConstFold.idr`）。
   呼び出しを含まない小さな呼び出し先は、呼び出し箇所に埋め込む（これにより、インターフェースメソッドの呼び出しをまたいで比較を融合できる）。
   定数の`ExtPrim`と、算術、比較、キャスト、定数に対するcaseの式は畳み込む。
   名前付きのトップレベル関数に対する、捕捉変数のないクロージャも、解放されない（immortal）定数に畳み込む。
   これだけで、クロージャを並べたインターフェース辞書の形のレコードを丸ごと消せる。
   `ConstFold.idr`の畳み込みは、上限付きのプログラム全体の不動点計算として実行する（最大4ラウンド。`--directive noconstfold`で無効化できる。`rc2/doc/directives.md`を参照）。
   別のトップレベルの引数0個の定義（CAF）を呼ぶ`RAppName`は、その定義自体が定数に畳み込まれるなら、呼び出し箇所で畳み込み結果に置き換える。
   この置き換えは、1つの関数本体の中にとどまらず、定義の境界も越える。
   また、検査対象がすでに畳み込み済みの定数コンストラクタだと分かっている`case`は、コンパイル時に、フィールドも含めて一致する分岐だけに縮約する。
7. **クロージャ適用の高速パス**。
   これはIRパスではなく、ランタイムのレベルで行う（`support/rc2/idris2rc2_rt.c`の`idris2rc2_applyClosure`）。
   共有されたクロージャに最後の引数を適用するとき、一時的なクロージャを確保してすぐ呼び出して捨てる代わりに、対象の関数へ直接ディスパッチする。
8. **単純な末尾呼び出しを超える再帰の形**。
   tail recursion modulo constructor（`x :: f xs`）は、新しいセルの穴を順に埋めるループにする（`Trmc.idr`、`rc2/doc/trmc.md`）。
   差分リストの累積引数（`c . (y ::)`）は、そのようなセルの連鎖として保持する（`ClosureCtx.idr`、`rc2/doc/closure-accumulator.md`）。
9. **特殊化と呼び出しの形の書き換え**。
   呼び出し先に渡される定数クロージャや定数のインターフェース辞書ごとに、呼び出し先を複製する（`SpecClosure.idr`、`rc2/doc/speculative-closure-specialization.md`、`rc2/doc/constant-constructor-specialization.md`）。
   worldを待つクロージャを返す関数は、world自体を引数に取るようにする（`ArityRaise.idr`、`rc2/doc/world-arity-raising.md`）。
   `where`関数の未使用の引数は取り除く（`DeadArgs.idr`、`rc2/doc/dead-args.md`）。
   フィールドが4つ以下のコンストラクタは、ワーカー関数からヒープ上のセルではなくCの構造体として値で返す（`rc2/doc/struct-return.md`）。
10. **実行時の値のコストを下げる**。
   `Int`/`Int64`/`Bits64`/`Integer`は、62ビットに収まる場合はポインタのワードの中に直接格納する（`rc2/doc/immediate-ints.md`）。
   参照カウントは、プログラムが実際に2つ目のスレッドを起動するまで、アトミックでない通常の命令で操作する（`rc2/doc/hybrid-refcount.md`）。

各パスの設計の根拠や、途中で見つけて直したバグは、`rc2/doc/*.md`の個別の解説にまとめてある。
索引の全体は`AGENT.md`のLayout節に、`RCExp` IR自体をダンプして読む方法（`--directive dumprcexpr`）は`rc2/doc/reading-the-ir.md`にある。
上記のほとんどについて、測定した効果を`rc2/BENCHMARKS.md`に記録している。
`rc2/tests/refc-suite/README.md`には、上流の回帰テストのうちrc2が対応している範囲と、上流と結果が異なる箇所を記している。
テストの移植や作成の過程で見つかったバグも、すべてそこに載せている。

### `libs/rc2base/`

```
libs/rc2base/
├── rc2base.ipkg   Idris2パッケージ: Control.Concurrent.{MVar,Atomic},
│                  Data.Text/Data.TextBuffer, Data.String.{FFI,RC2}, Data.Buffer.RC2,
│                  Data.Double.{RC2,Convert}, Data.IORef.RC2, Data.Integer.GMP, Data.Queue,
│                  Language.RCExpr.{AST,Lexer,Parser},
│                  Network.{RC2,URL}, Network.HTTP.{Route,Router,Server},
│                  System.Concurrency.RC2, System.FFI.C.{Array,Ptr,Sizeof},
│                  System.GC.RC2, System.IO.Epoll, System.IO.MemStream,
│                  System.Random.Xoroshiro{128PlusPlus,64StarStar},
│                  Text.Encoding.UTF8, Text.Regex.POSIX
├── src/           上記モジュールのIdris2ソース
├── support/c/     上記の大半を支えるCシム（libidris2rc2base.a）。prebuild/postinstallフックでビルドする
├── doc/           規模の大きい部分の設計ノート（http-router.md、http-server.md、regex-posix.md、url.md）
└── tests/         モジュールごとに1つのTestX.idr。rc2で直接実行する（verify.sh。rc2/tests/と同じ構成）
```

rc2に付属するサポートライブラリのパッケージである。
最初は、UTF-8を扱える`Data.Text`型（コードポイント単位で添字を付ける`String`とは別物）だけだったが、成長して、今ではrc2用の汎用的なネイティブC ABIツールキットになっている。
収録しているのは、上流の`base`/`contrib`にまったく無いもの、またはrc2の用途には部分的にしか応えないものである。
当初からあるのは、`Data.Text`、`Data.Integer.GMP`（`mpz_t`のFFI）、`System.Concurrency.RC2`（実際のOSスレッドとmutexのプリミティブ）、`System.Random`である。
このうち`System.Random`は、rc2にCバックエンドがない上流プリミティブの代わりに、一から書いた2つの実装を持つ（`TODO.md`の"Upstream stdlib `%foreign` declarations with no C/RefC backend at all"の項を参照）。
現在は、これらに加えて次のものも含む。

- 小さなイベント駆動のHTTP/1.1サーバ（`System.IO.Epoll`上に実装した`Network.HTTP.Server`）と、型安全なExpress風ルータ（`Network.HTTP.Route`/`Router`）
- URLの解析（`Network.URL`）
- POSIXの`<regex.h>`バインディング（`Text.Regex.POSIX`）。RE2のバインディングは兄弟パッケージの`libs/text-re2/`にある（下記を参照）
- 生のUTF-8バイト列とコードポイントの相互変換（`Text.Encoding.UTF8`）。rc2の通常のコードポイント単位の`String`ではなく、バイトオフセットを扱っている場面のためのものである
- rc2自身の参照カウントのプリミティブを直接操作する手段（`System.GC.RC2`）。不透明なFFIポインタ経由で受け渡す値のためのものである
- Haskell風の`MVar`とアトミックカウンタ（`Control.Concurrent.*`）
- rc2自身のIRダンプのパーサ（`Language.RCExpr.*`。`tools/rcexpr-lint`はこれを使ってダンプを読む）

モジュールごとの設計の根拠は、`libs/rc2base/README.md`にある。

ビルドとインストールはリポジトリのルートで行い、上記の`rc2`自身と同じ`install/`プレフィックスに入れる。
このプレフィックスは、`env.sh`が設定する`IDRIS2_PACKAGE_PATH`の先頭にすでにある。
したがって、インストール後にパッケージパスを別途設定する必要はない。
ここで`IDRIS2_PREFIX`をexportする必要もない。
`env.sh`が`PATH`に置く自前ビルドの`idris2`は、このリポジトリの`install/`を既定値として最初から指しているからである（ブートストラップ時に埋め込まれる。`idris2 --prefix`で確認できる）。

```sh
source env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)
```

`rc2/tests/verify.sh`は、すべてのスモークテストでこのパッケージにすでに依存している（`-p rc2base`。たとえば`Test118FFI/FFIInteger.idr`は`Data.Integer.GMP`を使う）。
そのため、通常どおり`verify.sh`を実行すれば、このパッケージも暗黙のうちにビルドされ、実際に使われる。
このパッケージ自身の`tests/verify.sh`（モジュールごとに`TestX.idr`/`.expected`の組が1つ）を直接実行する方法は、`libs/rc2base/README.md`の"Build & test"節にある。
同じREADMEの"Native library install location"節は、`postinstall`フックによる`lib/`へのコピーが、とくにrc2で重要になる理由を説明している。
Chez/Racketと違い、rc2は依存先パッケージの`lib/`ディレクトリを自動では見つけないからである。

### `libs/text-re2/`

```
libs/text-re2/
├── text-re2.ipkg   Idris2パッケージ: Text.Regex.RE2
├── src/            上記モジュールのIdris2ソース
├── support/c/      それを支えるC++シム（re2_util.cpp、libidris2rc2re2.so）
├── doc/regex.md    rc2baseに含めず独立したパッケージにした理由
└── tests/          TestRE2.idr。rc2で直接実行する
```

Googleの[RE2](https://github.com/re2)正規表現エンジンへのバインディングである。
`rc2base`を素のCツールチェーン（`gcc`/`ar`）だけでビルドできるように保つため、`rc2base`から独立したパッケージに分けた。
RE2のAPIはC++であり、しかも`pkg-config --libs re2`はabseilの`-l`フラグ数十個に展開される。
これは1つの`%foreign`の`lib`フィールドには収まらない。
そこでこのパッケージのシムは`g++`でコンパイルし、専用の`libidris2rc2re2.so`にリンクしている。
`re2`/`pkg-config`/`g++`が`PATH`上に必要になるのは、`Text.Regex.RE2`を実際に`import`するプログラムだけである。
よくある用途なら、`Text.Regex.POSIX`（`rc2base`に含まれ、libcだけで動き、外部依存がない）で足りる。
設計の根拠の全体とビルド・インストールの手順は、`libs/text-re2/README.md`とその`doc/regex.md`にある。
手順は`libs/rc2base/`と同じく、`IDRIS2_PREFIX`/`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`を設定したうえで、共有の`install/`プレフィックスにインストールする。

### `tools/rcexpr-lint/`

```
tools/rcexpr-lint/
├── RcexprLint.idr  CLI: .rcexprファイルを読み、異常1件につき1行を出力したあと、メトリクスを出力する
├── Lint.idr        検査本体（規則はこのモジュールの注記を参照）
├── Metrics.idr     静的な件数: 定義、コンストラクタの構築、クロージャ、呼び出し、dup/drop
├── README.md       検出するもの、意図的に検出しないもの、レポートの読み方
└── tests/          手書きの.rcexprフィクスチャとverify.sh
```

rc2が`--directive dumprcexpr`でダンプする`RCExp` IRの静的検査ツールである。
ダンプから各定義の参照カウントを導出し直し、次の2種類の問題を報告する。
どちらも、生成されたCの上ではクラッシュかリークとして現れるか、何の症状も出ないかのどちらかである。

- **use-after-free**: 所有しているカウントがすでに0になった`Boxed`のローカル変数を、もう一度読む。
- **double-drop**: カウントがすでに0の`Boxed`のローカル変数を、もう一度dropする。

このツールを作った理由は、`Compiler.RC2.Sink`にこの種類のバグが別々に3回入り込み、そのたびに、何時間もかけて手作業でダンプを追わなければ見つからなかったことにある。
valgrindでこの種のバグを検出できるのは、バグを引き起こすテストがあり、しかも解放済みのメモリが実際に再利用された場合に限られる。
このツールなら、コンパイルできる*どんな*プログラムのIRでも検出でき、外部パッケージ全体も対象にできる。

異常の報告のあと、ダンプ全体の静的なメトリクスを出力する。
内容は、種類別の定義数、コンストラクタの構築（新規確保か、セルの再利用か）、構築・適用されたクロージャ、呼び出し、表現別の`let`、分岐、`dup`/`drop`の件数である。
これらは実行回数ではなくIR上の箇所の数であり、1つのプログラムの2つのダンプを比べるために使う。
たとえば、あるパスを有効にした場合と無効にした場合（`--directive no<stage>`）を比べる。

```sh
source env.sh
# 任意のプログラムを、ダンプ用ディレクティブを付けてコンパイルする
rc2/build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr Prog.idr -o prog
tools/rcexpr-lint/build/exec/rcexpr-lint build/exec/prog.rcexpr
```

終了コードは、異常がなければ0、あれば1なので、そのままスクリプトに組み込める。
規則の全一覧、ビルドとテストの方法、既知の不正確さは`tools/rcexpr-lint/README.md`にある。
既知の不正確さとは、次のことである。
ダンプでは、`case`分岐で束縛されるフィールドに`Rep`が付かないため、すべて`Boxed`とみなしている。
そのため、nativeのフィールドで誤検出が起こりうる。

このツールを`rc2/`ではなく`tools/`の下に置いているのは、`rc2/`にコンパイラバックエンドだけを置く方針だからである（`AGENT.md`の"Layout"を参照）。

### `tools/rcexpr-diff/`

```
tools/rcexpr-diff/
├── RcexprDiff.idr  CLI: 2つの.rcexprダンプを定義ごとに比較する
├── README.md       何を同一とみなすか、オプション
└── tests/          手書きの2つのダンプとverify.sh
```

2つのIRダンプを定義ごとに比較するツールである。
比較の前に、変数を出現順に付け直し、rc2が生成する名前に含まれるカウンタを取り除く。
これにより、rc2への変更がどの定義に影響したかが分かる。
バイト単位のdiffでは、最初に変わったノード以降のすべての変数IDがずれるため、ファイル全体が差分として出てしまう。
詳しくは`tools/rcexpr-diff/README.md`を参照。

## ビルドと実行

```sh
cd rc2
source ../env.sh
nix-shell -p gcc gmp pkg-config --run 'idris2 --build rc2.ipkg && idris2 --install rc2.ipkg'
```

このコマンドは、`source ../env.sh`が`PATH`の先頭に置いた`idris2`でビルドする。
既定では、自前ビルドの`install/bin/idris2`である。
この`idris2`は、このリポジトリの`install/`プレフィックスを既定値として最初から指している（ブートストラップ時に埋め込まれる。`idris2 --prefix`で確認できる）。
そのため、`IDRIS2_PREFIX`をexportする必要はない。

プロジェクトの方針により、nixpkgsの`idris2`パッケージは現在ブートストラップ専用であり、特別な理由がなければrc2のビルドには使わない。
それでも1回だけ使いたい場合は、`-p`の一覧に`idris2`を戻し、*さらに*`IDRIS2_PREFIX`を再びexportする。
nixpkgsの`idris2`には、埋め込まれた既定値がなく、代わりに読み取り専用の自身のnix storeのパスを指している。
そのためexportしないと、`--install`は警告も出さずに、このリポジトリの`install/`ツリー以外へインストールしてしまう。

```sh
export IDRIS2_PREFIX="$(cd .. && pwd)/install"
nix-shell -p idris2 gcc gmp pkg-config --run 'idris2 --build rc2.ipkg && idris2 --install rc2.ipkg'
```

nix-shellは、`-p`で指定した各パッケージの`bin/`を、`PATH`の残りより前に追加する。
そのため、`env.sh`が自前ビルドの`install/bin`を`PATH`の先頭に置いていても、このシェルの中ではnixpkgsの`idris2`のほうが優先される。

ビルドすると`rc2/build/exec/idris2-rc2`ができる。
ランタイムライブラリ（`libidris2rc2.a`）は、rc2で*コンパイルした*すべてのプログラムにリンクされるもので、`idris2-rc2`自体にはリンクされない。
ランタイムは`rc2/support/rc2/`の下にあり、独立した`Makefile`を持つ（`libs/rc2base/rc2base.ipkg`が`support/c`を分けているのと同じ構成である）。
`rc2.ipkg`の`postbuild`/`postinstall`フックは、上の2つのコマンドの一部として、この`Makefile`を自動で実行する。
`--build`はランタイムをコンパイルし（`make -C support/rc2`）、`--install`はその結果を`install/idris2-0.8.0/support/rc2`にコピーする（`make -C support/rc2 install`）。
ランタイムのインストール先は`Makefile`自体からの相対位置で決まっており、`IDRIS2_PREFIX`には左右されない。
`IDRIS2_PREFIX`が影響するのは、*rc2パッケージ自身の*`.ttc`/`.ttm`の置き場所だけである。
コンパイラの再コンパイルを省いてランタイムだけを再ビルドしたい場合は、`rc2/support/rc2`の下で`make`/`make install`を直接実行してもよい。

実用的なプログラムのほぼすべてで、rc2には付属のサポートライブラリパッケージ[`libs/rc2base/`](#libsrc2base)（上記）も必要である。
理由は、上流の`%foreign`プリミティブのいくつかにrc2のCバックエンドがなく、`rc2base`のモジュールで差し替えて初めて使えるようになることにある。
該当するのは、`Data.Buffer`の`setInt8`/`getInt8`など、`Data.Double`の`unitRoundoff`/`epsilon`/`nan`/`inf`、GMPによる`Integer`の算術、`System.Random`である。
詳しくは`libs/rc2base/README.md`と、本ファイルの下記「上流RefCとの意図的な違い」節を参照。
このパッケージは一度だけビルドし、上記のrc2自身と*同じ*`install/`プレフィックスにインストールする。
idris2は既定で自身のインストールプレフィックスを探すので、インストール後は自動的に見つかり、パッケージパスを別途設定する必要はない。
上で述べたとおり、自前ビルドの`idris2`がすでにそこを既定値にしているため、`IDRIS2_PREFIX`のexportも不要である。

```sh
cd ..
source env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)
```

Idris2のプログラムをrc2でコンパイルするには、次のようにする。

```sh
nix-shell -p gcc gmp pkg-config --run \
  './rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base Program.idr -o program'
```

生成されたCは、既定では`-O2`でコンパイルする。これはランタイムライブラリと同じ最適化レベルである。
`IDRIS2_CFLAGS`（未設定なら`CFLAGS`）はコマンドライン上でその後ろに付き、`-O`は最後に指定したものが有効になる。
したがって`CFLAGS=-O0`で最適化を再び無効にできる（上流RefCは`-O`をまったく渡さない）。

ビルドの性能は、上流Idris2自身の`--timing N`フラグで確認できる（rc2専用のフラグは不要）。
`--timing 1`では、上流の`Compiler.Common`のラッパーがもともと表示している"Code generation overall"の合計時間が出る。
`--timing 2`では、この合計をさらに、rc2のパイプラインの段階ごとに分けて表示する。
段階は、inline、RC normalize、ConstFold、CAF memoization、RC annotate/reuse/ConAltNative、mutual loop、loop conversion、sink、dual ABI、dead-code elimination、dup merge、C generation、C compile、C linkであり、それぞれ`rc2: <stage>`というラベルが付く。
重い段階のいくつか（inline、loop conversion）は、`--timing 3`でさらに名前付きの下位フェーズに分かれる。
`--directive no<stagename>`で無効にした段階（`rc2/doc/directives.md`と、下記の`verify.sh`の`--directive`フラグを参照）は、所要時間0の項目が出るのではなく、計測行そのものが出ない。

## テスト

```sh
cd rc2/tests
source ../../env.sh
nix-shell -p gcc gmp pkg-config valgrind --run './verify.sh'
```

`verify.sh`は、正しさを確認するための一括実行の入口である。
次の処理を順に行う。

1. `idris2-rc2`とランタイムをビルドする。
2. 移植した上流の回帰テストスイート（`rc2/tests/refc-suite/`。そのディレクトリの`README.md`を参照）を実行する。
3. 手書きのスモークテスト（`rc2/tests/TestN/TestN.idr`）をすべてコンパイルし、保存済みの`TestN.expected`と出力を比較する。
4. リークに敏感なテストの部分集合に対して`valgrind --leak-check=full`を実行する。リークに限らず、あらゆるメモリエラーを失敗として扱う。`valgrind`が`PATH`上にない場合も、それだけで失敗とする（`--no-valgrind`を渡せば省略できる）。
5. 最後に、マルチスレッドのテストをThreadSanitizerの下で実行する（`tsan.sh`。単独でも実行できる）。

上流の参照用RefCに欠陥があるため、いくつかのテストは本物のRefCとの出力比較ができない。
該当する欠陥は`KNOWN-BUGS.md`にまとめてある。
ビルドも、`--regen-expected`が参照用に行う本物のrefcでのコンパイルも、`PATH`の先頭にある`idris2`を使う（上で`source`した`env.sh`経由の自前ビルド版）。

便利なフラグは次のとおりである。

- `--skip-build`: 既存の`idris2-rc2`を再利用する
- `--no-valgrind`: 速くなる
- `--valgrind-all`
- `--no-refc-suite`
- `--no-tsan`
- `--directive VALUE`: `idris2-rc2`にそのまま渡す。繰り返し指定できる。たとえば`--directive noloop`で最適化の段階を1つ無効にし、回帰の原因がその段階かどうかを切り分ける。ディレクティブの全一覧は`rc2/doc/directives.md`を参照
- `--regen-expected`: スモークテストを追加・編集したあとに使う

環境変数`TEST_TIMEOUT`（秒、既定値60）は、テストプログラム1回の実行時間の上限である。
上限を過ぎても動いているプログラムは強制終了され、タイムアウトとして報告される。
valgrindとThreadSanitizerでの実行には、その10倍の時間が与えられる。
フラグの全一覧と、`idris2-rc2`ができたあとでスモークテストを1つだけ手で再実行する方法は、`verify.sh`の先頭のコメントにある。

`verify.sh`の隣には、さらに2つのスクリプトがある。
どちらも、リファクタリングや高速化のように、rc2の出力を変えないはずの変更のためのものである。
`snapshot.sh save DIR` / `snapshot.sh diff DIR`は、2回の`verify.sh`の実行が`rc2/tests/build/`に残したIRダンプとCを、バイト単位で比較する。
`nopass.sh`は、最適化の段階を1つずつ無効にして、スモークテストを段階ごとに1回ずつ実行する。
これにより、別のパスに暗黙のうちに依存しているパスを見つけられる（その段階の効果を`check.sh`で確認しているテストは、そのとき当然失敗する）。
また、`verify.sh`は、すべてのスモークテストのIRダンプを`tools/rcexpr-lint`にもかける。

```sh
cd rc2/tests
nix-shell -p gcc gmp pkg-config --run './bench.sh'
```

`bench.sh`は、性能を測るための同様の一括実行の入口である。
`rc2/tests/Bench*.idr`をすべて、`idris2-rc2`と本物の`idris2 --cg refc`の両方でコンパイルして計測し、実時間での速度向上比を報告する。
ビルドも、本物のrefcで比較する側も、常に`PATH`の先頭にある`idris2`（`env.sh`経由の自前ビルド版）を使う。
`--runs N`は、バイナリごとの繰り返し回数を指定する。
`--missing-containers`を付けると、外部パッケージ`idris2-missing-containers`のベンチマークも実行する。
これには、`nix-shell -p`の一覧にも`chez`を加える必要がある。
事前に何を用意する必要があるかは、`rc2/BENCHMARKS.md`の計測方法の節にある。
記録済みの結果とその読み方も、同じ`rc2/BENCHMARKS.md`にある。

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

3つ目の手段が`tools/rcexpr-lint`である。
ダンプした`RCExp` IRの参照カウントを静的に検査し、出力の比較でもvalgrindでも確実には捕まえられない、use-after-free/double-dropの類のバグを対象にする（上記の`tools/rcexpr-lint/`と、このツールの`README.md`を参照）。
`tests/verify.sh`は、ツールをビルドし、手書きのフィクスチャに対して検査する。
`dup`/`drop`を挿入したり移動したりするパスを変更したあとは、ビルドしたCLIを実際のプログラムの`.rcexpr`ダンプにも実行しておく価値がある。

## 上流RefCとの意図的な違い

Idris2自身の仕様では、`Char`は完全なUnicodeスカラー値（`0..0x10FFFF`、サロゲートの範囲を除く）であり、ChezとJSのバックエンドもそのように扱っている。
一方、上流RefCはランタイム全体で`Char`を1バイトのCの`char`に切り詰めている（`support/refc/casts.h`の数値から`Char`へのキャスト、`idris2_vp_to_Char`のデコードマクロ）。
rc2は意図的にこれに従わない。
rc2の数値から`Char`へのキャスト（`support/rc2/idris2rc2_numeric.h`の`idris2rc2_charFromCodepoint`。Chezの`cast-int-char`と同じ動作）も、boxedの`Char`表現も、32ビットのコードポイント全体を保持する。
そのため、Unicodeの有効範囲外の値は、切り詰めで残った下位ビットによって別の文字に気づかないうちに解釈されることはなく、NULに対応付けられる。

意図的な例外が1つある。
`Char`として束縛した`CFStruct`のフィールド（`Emit.idr`の`genStructDef`、`Emit/Util.idr`の`cTypeOfCFType`）は、今でも本物の1バイトのCの`char`を使う。
このフィールドの型は、実際のCライブラリの構造体レイアウト（サイズ、オフセット、アラインメント）とバイト単位で一致しなければならない。
ここを`uint32_t`に広げても、何も直らず、隣のフィールドを壊すだけである。

`String`にも同じ事情がある。
Idris2自身の仕様（およびR6RSが定めるChezのネイティブ文字列型）では、`length`、添字アクセス、`substr`、`pack`、`unpack`、`reverse`、`Data.String.Iterator`は、Unicodeの*コードポイント*単位で動く。
上流RefCはこれらをバイト単位で扱う（`support/refc/stringOps.c`）。
rc2はこれにも意図的に従わない。
`support/rc2/idris2rc2_strings.c`の`String`プリミティブは、共有のコーデック`support/rc2/idris2rc2_utf8.c`を通じて、コードポイント単位でデコード、長さの計測、切り出しを行う。
一方で、バッファはすべて実際のUTF-8の*バイト*長に基づいて確保し、2つの数を取り違えることはない（各プリミティブがどちらのバイト数に基づいて確保するかは、そこにある各プリミティブのコメントを参照）。
不正なバイト列（たとえば`CFString`型の`%foreign`引数や、`Buffer -> String`の変換から来たもの）は、クラッシュも誤読もせず、U+FFFDにデコードする。
これは、損失のあるデコードについてUnicode自身が定める、標準の置換文字の慣例である。

受け入れたうえで、そのままにしている帰結が1つある。
Chezのネイティブな固定幅の文字配列では`string-ref`がO(1)だが、rc2はUTF-8のバイトバッファの表現を維持している。
そのため、コードポイント単位のアクセス（`strIndex`/`strSubstr`/`strTail`）は、文字列の先頭から走査するので1回あたりO(n)かかる。
つまり、Chezの*意味論*には合わせているが、*内部表現*までは合わせていない。
このトレードオフと、この作業で手が届かなかった穴が1つあることは、`TODO.md`に書いてある。
なお、不正な入力や悪意のある入力に対するバイト単位の`String`<->`Char`変換は別として、*値自体の格納幅*は上記の`Char`の作業ですでに直してある。

`String`をNUL終端のC文字列ではなく本物のバイトバッファとして扱うことには、もう1つ帰結がある。
上流RefCの`String`表現（素の`char *`）は、埋め込まれたNULバイトをそもそも保持できず、最初のNULより後ろはすべて失われる。
`IDRIS2RC2_String`（`rc2/support/rc2/idris2rc2_datatypes.h`）は、バッファ本体と並べて、明示的なバイト長のフィールド（`len`）を持つ。
`len`の大きさは、ヘッダのアラインメントによってポインタの前にもともと生じているパディングを再利用できるように決めてある（`rc2/doc/constructor-layout.md`を参照）。
これにより、`String`はNULバイトを保持し、正しく往復させられる。
`length`、`substr`、`++`、等価比較と順序比較（`strcmp`ではなく、バイト長を比べてから`memcmp`）、`pack`/`unpack`、`String`リテラルに対するパターンマッチ（`case`）は、いずれもバッファの終端文字ではなく`len`を使う。
パターンマッチは、`strcmp`ではなく、`len`を比べてから`memcmp`する検査としてコンパイルする。
したがって`cast '\0' : String`は`""`ではなく`"\NUL"`になる。
この回帰テストが`rc2/tests/Test124StringNul`である。

`rc2/tests/refc-suite`の`basicpatternmatch`テスト（`"abcde\0fg" => "1st\02nd"`。ソース中に`-- Issue 3161`と注記がある）は、上流自身のテストスイートに現れた同じ問題である。
本物のRefCは`strcmp`に基づいてcaseを振り分けるので、NULの位置で切れて誤った分岐にマッチするが、rc2はそうならない。
そのテストの`expected`ファイルへの反映のされ方は、`KNOWN-BUGS.md`を参照。

バッファ本体（`str`）はそれとは関係なく常にNUL終端しているので、素の`char *`としてCに渡すこともできる。
ただし、これがこの設計で受け入れている唯一の制限であり、`len`フィールドでも完全には解消できていない。
通常の`char *`型のFFI境界（`%foreign`の引数、`%export`した関数の素の`String`の戻り値、`String`から数値へのキャスト）を越える`String`は、今でも`->str`/`strlen`で読む。
そのため、そこでは最初の埋め込みNULで切れる。
これが影響する具体的な`Prelude`/`Data.String.Iterator`のプリミティブと、rc2が可能な範囲でそれを回避する方法（`fastPack`/`fastConcat`/`fastUnpack`/`Data.String.Iterator.uncons`/`withIteratorString`）は、`rc2/doc/fastpack-fix.md`にある。
なお、長さが`UINT32_MAX`バイトを超える場合は、値が気づかないうちに一周するのではなく、異常終了する（`idris2rc2_checkedStrLen`）。

並行処理にも似た事情があり、規模はさらに大きい。
上流Idris2の`System.Concurrency`モジュール（`Mutex`/`Condition`/`Semaphore`/`Barrier`/`Channel`/`getThreadId`/`setThreadData`/`getThreadData`）は、これらをすべて、Schemeだけで実装された`%foreign`プリミティブとして宣言している（`scheme:blodwen-make-mutex`など）。
RefCを含め、これまでどのCバックエンドも、これらのどれも呼び出せなかった。
`fork`自体は1段下にあり、コンパイラのコアのプリミティブである。
どのバックエンドも、自前の`prim__fork`の実装を用意しなければならない。
上流RefCの実装（`support/refc/threads.c`）は1関数だけのスタブで、"Threads not implemented in the RefC backend!"と表示して`exit(0)`を呼ぶ。
スレッドをまったく生成しないので、上記の`%foreign`宣言が何を対象にしていたとしても、その上に載るものはどれも使えなかった。

rc2はこれにも意図的に従わない。
まず参照カウントをアトミックにした（`support/rc2/idris2rc2_datatypes.h`、`idris2rc2_memory.c`、`idris2rc2_runtime.h`）。
その後、アトミックにするのは2つ目のスレッドが存在するときだけに変えている（`rc2/doc/hybrid-refcount.md`を参照）。
次に`refc_fork`（`support/rc2/idris2rc2_ioprims.c`）を書き直し、スタブをやめて、デタッチ状態の本物の`pthread`を生成するようにした。
そのうえで`%foreign_impl`を使い、上流の`Mutex`/`Condition`/`Semaphore`/`Barrier`/`Channel`/`conditionWaitTimeout`/`getThreadId`/`setThreadData`/`getThreadData`を、本物のpthreadのオブジェクトで実装した（`libs/rc2base/src/System/Concurrency/RC2.idr`、`libs/rc2base/support/c/concurrency_util.c`）。
`%foreign_impl`はIdris2に既存のディレクティブで、別のモジュールにある*既存の*プリミティブ宣言に、上流のソースに手を加えずに具体的な実装を結び付ける。
呼び出し側は、通常の`System.Concurrency`に加えて`System.Concurrency.RC2`を1つimportするだけで、これらをすべて使える。
上流の型名と関数名は、そのまま変更なしに動く。

`Channel`の`channelGetNonBlocking`/`channelGetWithTimeout`をこの方式で動かすには、範囲を限定し、明示的に文書化した前提が1つ必要になる。
rc2のランタイムには、汎用のCコードから、任意のコンパイル結果における`Just`のタグを、プログラムに依存せずに組み立てる手段がない。
しかし`Prelude.Maybe`は、プログラムごとにユーザーが定義するADTではなく、固定された1つのライブラリ型である。
その`Just`が常にtag=1/arity=1であることは、経験的に確認している。
`concurrency_util.c`の`idris2rc2_channel_wrap_just`は、この前提に基づいて、`Constructor`を省略せず本物の`Constructor`を組み立てる。
そのため、ペイロード自体が`NULL`で表現できる場合（`Just []`、`Just ()`）でも健全である。
この点が、一般的な「`Just x`を`x`にアンラップする」最適化との違いである。
その最適化は、まさにこの理由で調査のうえ見送ったと`TODO.md`に記録している。

同じモジュールには、上流に相当するものがまったくない機能も1つある。
join可能なfork（`forkJoin`/`join`/`JoinHandle`）である。
これを追加したのは、上流の`threadWait`がSchemeだけの実装で、`Mutex`と同様にどのCバックエンドからも呼び出せないからである。
設計の経緯の全体と、アトミックな参照カウントのメモリオーダーについての考察は、`rc2/doc/concurrency.md`にある。

`%export "lang:name"`にも同じ方針を取るが、こちらはさらに外向きの話になる。
上流RefCはこのプラグマを完全に無視する（C ABIのマーシャリングを一切行わない）。
JSバックエンドは名前のマングリングを外すだけで、中身はJSのクロージャのままであり、ネイティブの呼び出し境界にはならない。
rc2は本物のネイティブC ABIのラッパーを生成する。
ラッパーは、入ってくるネイティブの引数をboxし、返すネイティブの結果をunboxする。
対象は、次の型を持つexportされた関数である。

- スカラー型（`Int`/`Int8`/.../`Double`/`Char`、およびそれらの`IO`/`IORes`）
- `Ptr`/`AnyPtr`
- `GCPtr`/`GCAnyPtr`（引数のみ。`GCPtr`の戻り値はファイナライザのタイミングの危険があるため、コンパイル時に拒否する）
- `Integer`（GMP、引数と戻り値の両方向）
- `String`（戻り値には、呼び出し側が`free()`する明示的なコピーが必要）
- 構造体（ポインタ渡し。`Ptr`と同じ仕組み）

これらの関数は、Idris/rc2のAPIを一切使わずに素のCから呼び出せる（`rc2/tests/Test59Export/`に付属する`.c`は、自身のプログラムがexportしたシンボルをCFTypeの形ごとに1節ずつ直接呼び出す）。
対応範囲の全体、所有権についての取り決め、途中で見つけて直した原因の分かりにくいバグ1件（`%export`した名前が、デッドコード除去を通っても正しく残されるようになった）は、`rc2/doc/export-support.md`にある。

プロセスの起動処理にも、小さな違いが1つある。
RefCが生成する`main()`は、argvを設定してエントリポイントを実行するだけである。
rc2の`main()`は、その前後でランタイムのライフサイクルのフックを2つ呼ぶ。
先に`idris2rc2_rtInit()`、あとに`idris2rc2_rtFinish()`である（`support/rc2/idris2rc2_rt.c`）。
`rtInit`は`setlocale(LC_ALL, "")`を実行し、環境のUTF-8ロケールを実際にlibcへ反映させる。
これがないと、Cプログラムは`LANG`/`LC_*`にかかわらず`"C"`ロケールのままになる。
その場合、`libs/rc2base`の`Text.Regex.POSIX`はバイト単位でマッチする（`.`は1バイト、`[[:alpha:]]`はASCIIだけ）。
`rtFinish`は`fflush(NULL)`である。
`--directive nomain`でビルドする場合は自前の`main()`を用意するので、両方のフックを自分で呼ばなければならない。

数値の書式化は、このロケールの影響を意図的に受けないようにしている。
`Double <-> String`の変換（`support/rc2/idris2rc2_numeric.c`）は、`.`を小数点とする10進変換を自前で行う。
パーサはGMPで正確に計算し、フォーマッタは往復で元の値に戻る最短の10進表記を出力する（RefCは`"%f"`で固定の6桁を出力し、`LC_NUMERIC`に従う。rc2はそのどちらもしない）。
そのため、`show`/`cast`の結果はどのロケールでもバイト単位で同一になる。
ただし、rc2の`String`層は、数値の書式化以外で外から入ってくるCのバイト列を、すべてUTF-8として扱う。
このため、環境のロケールを採用した以上、rc2のプログラムにはUTF-8互換のロケールが必要になる。
詳しくは`rc2/doc/runtime-lifecycle.md`を参照。

CAFの共有は、rc2が上流RefCとの振る舞いの差を埋めてきた例のうち、最大のものである。
上記の`Mutex`や`%export`は、RefCにそもそもなかった機能を補ったものだった。
CAFの共有では、RefCが明確に*誤った*結果を出す。
実際の副作用を持つ、通常のトップレベルの引数0個の定義を考える。

```idris2
counter : IORef Int
counter = unsafePerformIO (newIORef 0)
```

この定義は以前、rc2でも上流RefCでも**同じように**通常のC関数にコンパイルされていた。
そのため、参照するたびに再実行され、そのたびに自身の`IORef`を確保し直していた。
共有される1つのカウンタではなく、独立した3つのカウンタができてしまう。
`--cg chez`では、すでに正しい結果が出ていた。
現在は、`Compiler.RC2.RCExp`の新しい`RMemoize`ノードが、生き残った定数でないトップレベル定義すべての本体を包む。
このノードは、`Compiler.RC2.RC2`の`insertMemoize`が、プログラム全体の`ConstFold`の直後にプログラムごとに1回挿入する。
ノードの内容は、アトミックに確認し、計算し、キャッシュし、共有する一連の処理である（`support/rc2/idris2rc2_caf_memoize.h`/`.c`）。
`rc2/tests/Test86CafMemoization`は、Chezと同じく`0 1 2`が出力されることを確認する。
以前のrc2（と現在も本物のRefC）では`0 0 0`が出力されていた。
設計の全体は`rc2/doc/caf-memoization.md`にある。

`Lazy`/`Inf`のメモ化は、これに関連する差を1段上の層で埋める。
上流RefCは、上流のラムダリフティングをそのまま使う。
このラムダリフティングは、`Delay`を通常のクロージャに、`Force`をその適用に変換する。
そのため、同じ遅延値を2回以上forceすると、そのたびに最初から再実行してしまう。
rc2はラムダリフティングを自前で行い（`rc2/doc/lambda-lifting.md`）、`Delay`/`Force`を、lazyセルに対する独自のIRノード`RDelay`/`RForce`として保持する。
`idris2rc2_force`は最初の結果を保存し、同じセルに対するそれ以降のforceすべてでその結果を共有する。
Chez自身のネイティブな`(delay e)`/`(force e)`が、Chezバックエンドでこの問題にどこまで役立ち、どこで役立たないかは、`rc2/doc/lazy-memoization.md`の"What Chez does"にある。

## `%cg rc2`ディレクティブ

rc2は、汎用のソースプラグマ`%cg rc2 <directive>`を読む（CLIの`--directive VALUE`フラグで指定したものと合わせて扱う）。
用途は次の3つである。

- パイプラインの個々の段階をA/B比較のために無効にする（例: `--directive noloop`）
- デバッグ用のダンプ（`dumprcexpr`、`dumpdualabi`、`dumpcc`）
- 任意のCコードを生成出力に直接埋め込む（`extraRuntime=<path>`、`inlineRuntime=<code>`）。素の`%foreign "C:funcName"`宣言と自然に組み合わせられ、静的ライブラリやCFLAGS/LDFLAGSを別途設定する必要がない

ディレクティブの全一覧、`inlineRuntime`の2つの落とし穴、それぞれのディレクティブが存在する理由は、`rc2/doc/directives.md`にある。

## インクリメンタルコンパイル（`--inc rc2`）

RefCはインクリメンタルコンパイルにまったく対応しておらず、毎回のビルドがプログラム全体を一から行う。
rc2は対応している。
上流の`Codegen.incCompileFile`/`incExt`の仕組み（Chezが使うのと同じもの）を実装しており、`idris2-rc2 --cg rc2 --inc rc2 -o program Program.idr`は、各モジュールを一度だけそれぞれの`.o`にコンパイルする。
以降のビルドでは、プログラム全体のCを毎回生成し直す代わりに、その`.o`を再利用する。
次の点を検証済みである。

- `prelude`/`base`/`linear`/`contrib`/`network`を完全に再ビルドした（272モジュール、インクリメンタル用データの欠落は0件）。
- 実際の実行ファイルを`--inc rc2`でビルドし、正しく実行できた。素の`putStrLn`だけでなく、`Data.List`/`Data.SortedMap`を使うものも含む。
- 1ファイルを編集して再ビルドすると、そのファイルだけが再コンパイルされた。

これには、フックをつなぐだけでは済まない実質的な変更が必要だった。
rc2のC出力は、それまでプログラム全体の`defs`の一覧に対してしか動かしたことがなかったからである（プログラム全体を対象とする各パスのドキュメントコメントもそれを前提にしており、暗黙のうちに前提にしているものもあった）。
必要だった変更は次のとおりである。

- モジュールが参照するが自身では所有しないコンストラクタや関数を、前方宣言する。
- `%foreign`宣言や構造体の`getField`/`setField`のラッパーを、ハードエラーにせず取り除く。これらは、プログラム全体のデッドコード除去が先に取り除いていたおかげで動いていただけだった。
- 蓄積した`.o`ファイルを直接リンクせず、アーカイブにまとめる（直接リンクすると、何か1つの理由で必要になったモジュールが、たまたま定義している*ほかの*関数まですべて引き込んでしまう）。
- MutualLoop内部の名前生成器の1つについて、プログラム全体で1つのカウンタを前提にせず、モジュールごとに一意な名前を付けるようにする。

見つけたバグのすべて、行き詰まったいくつかの試み、上流のインクリメンタルの仕組み自体にある連鎖的な脆さ（rc2固有の問題ではない）についての知見は、`rc2/doc/incremental-compile.md`に詳しく記録している。

当面解消する予定のない、実際の制限が1つある。
**`--inc rc2`ではCの構造体（`getField`/`setField`/`Struct`）に対応していない。**
これらのラッパーは、呼び出し元にインライン化されて初めて正しい形になる。
単独で再利用できるオブジェクトファイルとして一度だけコンパイルする方式とは、根本的に両立しない。
これらを使うプログラムをインクリメンタルにビルドすると、*リンク*に失敗する（通常の未定義参照エラーであり、クラッシュや、気づかないうちの誤コンパイルではない）。
プログラム全体のコンパイル（既定）にはまったく影響しない。
また、日常的に実際の恩恵を得るには、`prelude`/`base`/`contrib`/`network`自体を少なくとも一度`--inc rc2`で再ビルドしておく必要がある（ツールチェーンに対する一度きりの作業であり、プロジェクトごとには不要）。
詳しくは、`rc2/doc/incremental-compile.md`の"practical prerequisite"節を参照。

## 現状と対象範囲

外部Cバックエンドとして動作しており、Idris2自身のRefC回帰テストスイート（`rc2/tests/refc-suite/`）と55個の手書きスモークテストに対して機能的に正しい。
リークに敏感なテストは`valgrind`でリークがなく、マルチスレッドのテストはThreadSanitizerで問題が出ない。
実装済みの機能は次のとおりである。

- コンストラクタのその場再利用
- native型の推論（関数内、および二重呼び出し規約による通常の呼び出し境界をまたいだもの）
- 自己末尾呼び出しと相互末尾呼び出しのループ変換と、ループ不変なパラメータ・式の巻き上げ
- tail recursion modulo constructor
- 分岐局所への沈め込み
- プログラム全体のインライン化
- クロージャと定数辞書の特殊化
- world引数のarity raising
- 構造体での戻り値
- 定数畳み込み
- プログラム全体のデッドコード除去
- dupのまとめ処理
- 即値整数
- マルチスレッドになるまでは通常の命令で行う参照カウント
- CAFと`Lazy`/`Inf`のメモ化（RefCにもともとなかった機能を補っただけでなく、上流RefCに対する実際の振る舞いの修正でもある。上記を参照）
- インクリメンタルコンパイル（上記を参照）
- `Data.Buffer`/`System.Clock`/標準の`network`パッケージ（rc2独自のネイティブな`idrnet_*`の移植）

既知の不足と、意図的に対象外とした判断の一覧は`TODO.md`にあり、現在も積極的に更新している（例: 末尾位置の委譲呼び出しがboxedのままであること、`LateInline`後のコンストラクタのエスケープ解析、小さなオブジェクト用のアロケータ）。
そこにある各項目には、何を試し、何が分かり、なぜそこで止めたのかを書いている。
