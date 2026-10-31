# idris2-rc-cg (rc2)

*[English](README.md)*

idris2-rc-cg（rc2）は、依存型プログラミング言語[Idris 2](https://github.com/idris-lang/Idris2)のための高速で堅牢な、独立した外部C言語コード生成バックエンドです。

Idris 2公式のCバックエンド（RefC）の基本設計（値の表現、参照カウント、クロージャ機構）を手本にしつつ、上流RefCの根本的な制約を解決しています。提供するのは、Perceus方式の参照カウント最適化パイプライン、POSIXスレッドによる本格的なマルチスレッド並行処理、厳密なUnicode準拠、インクリメンタルコンパイル、そして実用的なネイティブC ABI連携ツールキットです。

rc2は、上流のIdris 2本体を変更せずに開発されています。手を加えていない参照用のIdris 2チェックアウトと同じ場所に独自のリポジトリを置き、完全に独立した実行ファイル`idris2-rc2`としてビルドします。

---

## 目次

- [主な特徴とハイライト](#主な特徴とハイライト)
- [クイックスタート](#クイックスタート)（[環境準備](#1-環境変数の準備) / [ビルド](#2-rc2本体のビルドとインストール) / [ライブラリ導入](#3-サポートライブラリrc2baseのインストール) / [コンパイル実行](#4-プログラムのコンパイルと実行) / [性能計測](#ビルド時の性能計測--timing)）
- [付属エコシステムと開発ツール](#付属エコシステムと開発ツール)（[rc2base](#libsrc2baseネイティブc-abiツールキット) / [control-async](#libscontrol-asyncタスクとノンブロッキングソケット) / [web](#libswebhttpクライアントとサーバ) / [text-re2](#libstext-re2google-re2正規表現バインディング) / [notcurses・termui](#その他のバインディングnotcurses-termui) / [rcexpr-lint](#toolsrcexpr-lintir静的解析バグ検出ツール) / [rcexpr-diff](#toolsrcexpr-diffir差分比較ツール)）
- [アーキテクチャと最適化パイプライン](#アーキテクチャと最適化パイプライン)（[リポジトリ構成](#リポジトリ全体の構成) / [コンパイラ内部構成](#コンパイラ本体rc2の内部構成) / [最適化パス](#主要な最適化パス10の技術的柱)）
- [上流RefCとの意図的な違い・改善点](#上流refcとの意図的な違い改善点)（[Char](#1-完全なunicodeスカラー値に対応したchar) / [String](#2-コードポイント準拠とnul終端安全なstring) / [pthread](#3-本物のマルチスレッド並行処理pthread) / [%export](#4-ネイティブc-abiとの直接連携export) / [ライフサイクル](#5-プロセスのライフサイクルとロケール非依存な数値書式化) / [CAF・Lazyメモ化](#6-正しい意味論を保証するcafとlazy--infのメモ化)）
- [%cg rc2ディレクティブによるチューニング](#cg-rc2ディレクティブによるチューニング)
- [インクリメンタルコンパイル（--inc rc2）](#インクリメンタルコンパイル--inc-rc2)
- [テストと品質保証](#テストと品質保証)（[verify.sh](#一括回帰テストverifysh) / [snapshot・nopass](#出力を変えない変更の検証snapshotsh-nopasssh) / [bench.sh](#性能測定ベンチマークbenchsh) / [IRリンター](#irリンター単体テスト)）
- [現状とサポート範囲](#現状とサポート範囲)

---

## 主な特徴とハイライト

### 独立したIRパスによる高精度な参照カウント（Perceus / Koka方式）
RefCは、Cコードを出力する途中で、参照カウントの判断をアドホックに差し込みます。rc2はこれと違い、ANF正規化した中間表現`RCExp`の上で、所有権解析を独立したパスとして実行します。明示的な`RDup`、`RDrop`、`RFree`ノードは一度だけ挿入されます。そのため後続の最適化は厳密に健全なまま保たれ、C出力は機械的な変換だけになります。

### コンストラクタのその場再利用（In-place Reuse）
パターンマッチで分解した値が実行時に一意に所有されている（参照カウントが1）場合、rc2は同じ形状のセルを解放して確保し直さず、既存のヒープセルをその場で更新します。

### ネイティブ型推論（Unboxing）と二重ABI（Dual ABI）
固定幅の数値の中間値は、unboxedなnative値として推論されます。二重呼び出し規約（`DualABI`）により、native値は関数境界を越えてもボックス化されません。ループ変換は、自己末尾再帰と相互末尾再帰のループ全体でカウンタをアンボックスのまま保ちます。頻繁に読まれるフィールドは、native shadowとしてキャッシュされます（`ConAltNative`）。

### 本物のマルチスレッド並行処理（POSIX Threads）
上流RefCのスタブ（`exit(0)`）に代えて、rc2は本物のデタッチされた`pthread`を起動します。ハイブリッド参照カウントは、第2スレッドが実際に生成されるまで高速な非アトミック命令を使います。シングルスレッドの処理にアトミック操作のコストは一切かかりません。

### 厳密なUnicode準拠とNUL安全な文字列
`Char`は32ビットのUnicodeスカラー値を保持し、`String`はChez Schemeと同じコードポイント単位の意味論に厳密に従います。ヘッダのパディングに明示的なバイト長フィールド（`len`）を持つため、埋め込みNUL（`\0`）を含む文字列も、切り捨てられることなく往復でき、パターンマッチも安全に行えます。

### ネイティブC ABIラッパーの自動生成（`%export`）
rc2は、`%export`で公開したIdris 2関数に対して、本物のネイティブC ABIラッパーを生成します。スカラー型、GMP `Integer`、文字列、ポインタ、構造体のマーシャリングとボックス化・アンボックス化は自動で行われます。素のCコードは、ランタイムの内部表現を知らなくてもIdris関数を呼べます。

### インクリメンタルコンパイル（`--inc rc2`）
rc2はモジュールごとに個別のオブジェクトファイル（`.o`）へコンパイルし、ビルドをまたいで再利用します。反復開発中のコンパイル時間は大幅に短くなります。

### 充実したネイティブツールキット
rc2は、広範なネイティブツールキットを同梱しています。`MVar`を備えた`libs/rc2base`、`Task`スケジューラを備えた`libs/control-async`、HTTPクライアントとHTTP/1.1サーバを備えた`libs/web`、Google RE2バインディング、そして静的IR検査ツール`tools/rcexpr-lint`です。`tools/rcexpr-lint`は、use-after-freeやdouble-dropのバグを、実行前に静的に検出します。

---

## クイックスタート

### 1. 環境変数の準備

リポジトリをクローンしたら、環境設定ファイルを生成してシェルに読み込みます。

```sh
./gen-env.sh
source env.sh
```

- `gen-env.sh`は`env.sh`を生成します。`env.sh`は、自前ビルドのコンパイラがある`install/bin`を`PATH`に加え、サポートライブラリのパスも設定します。`idris2 --build`のChez Schemeバックエンドの段階にはChez Schemeが必要で、Idris 2は環境変数`CHEZ`から実行ファイルを取得し、なければ`PATH`上の`chez`、`chezscheme`、`chez-scheme`、`chezscheme9.5`、`scheme`のいずれかを探します（`gen-env.sh`自身が確認するのは`scheme`だけです）。
- `idris2-src/`は`https://github.com/idris-lang/Idris2.git`のクローンです。参照資料として、また自前ビルドのIdris 2コンパイラのブートストラップ元としてのみ使います（編集しません）。
- `install/`はビルド成果物のローカルインストール先です（gitignore対象）。

### 2. rc2本体のビルドとインストール

```sh
cd rc2
source ../env.sh
idris2 --build rc2.ipkg && idris2 --install rc2.ipkg
```

- `source ../env.sh`により、自前ビルドの`install/bin/idris2`が`PATH`の先頭に置かれます。このコンパイラはブートストラップ時に`install/`を既定のプレフィックスとして埋め込んでいるため、`IDRIS2_PREFIX`のexportは不要です。
- *（注：nixpkgsの`idris2`でビルドする場合は、`export IDRIS2_PREFIX="$(cd .. && pwd)/install"`を明示的に指定する必要があります。nixpkgsの既定は、読み取り専用のnix storeのパスを指すためです）*
- ビルドにより、実行ファイル`rc2/build/exec/idris2-rc2`が生成されます。
- rc2でコンパイルした全プログラムにリンクされるランタイムライブラリ（`libidris2rc2.a`）は`rc2/support/rc2/`にあります。`rc2.ipkg`のフックで自動的にビルド・インストールされ、`make -C support/rc2 && make -C support/rc2 install`で単独に再ビルドすることもできます。

### 3. サポートライブラリ（rc2base）のインストール

実用的なプログラムのほとんどでは、付属のサポートライブラリ[`libs/rc2base/`](#libsrc2baseネイティブc-abiツールキット)が必要です。上流の`%foreign`プリミティブのうち、RefC用の実装がないもの（GMPによる`Integer`演算、`Data.Buffer`の一部、`Data.Double`の定数、`System.Random`など）に、C実装を提供するためです。

```sh
cd ..
source env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)
```

- 自前ビルドの`idris2`は、既定で自身のインストール先（`install/`）を探します。そのため、ここにインストールしたパッケージは、パッケージパスを追加設定しなくても自動的に見つかります。

### 4. プログラムのコンパイルと実行

rc2コード生成バックエンドで、Idris 2のプログラムをコンパイルします。

```sh
./rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base Program.idr -o program
./program
```

- 生成したCコードは、ランタイムライブラリと同じ`-O2`で既定でコンパイルされます。
- 最適化を無効にするには、`CFLAGS=-O0`を渡すか、`IDRIS2_CFLAGS`を設定します。

### ビルド時の性能計測（--timing）

上流Idris 2の`--timing N`フラグで、コード生成パイプラインの所要時間を確認できます。

- `--timing 1`：コード生成全体の合計時間（"Code generation overall"）を表示します。
- `--timing 2`：合計時間を、`rc2: <stage>`というラベルのrc2パイプライン段階ごとに分けて表示します（inline, RC normalize, ConstFold, CAF memoization, RC annotate/reuse/ConAltNative, mutual loop, loop conversion, sink, dual ABI, dead-code elimination, dup merge, C generation, C compile, C link）。
- `--timing 3`：計算量の大きい段階（inlineやloop conversionなど）を、名前付きの下位フェーズにさらに分けて表示します。
- `--directive no<stage>`で無効にした段階は、実際には0であるかのような所要時間を出さず、計測行そのものを出力しません。

---

## 付属エコシステムと開発ツール

### `libs/rc2base/`：ネイティブC ABIツールキット

```
libs/rc2base/
├── rc2base.ipkg   Idris2パッケージ: Control.Concurrent.{MVar,Atomic},
│                  Data.Text/Data.TextBuffer, Data.String.{FFI,RC2},
│                  Data.Double.{RC2,Convert}, Data.IORef.RC2, Data.Integer.GMP, Data.Queue,
│                  Language.RCExpr.{AST,Lexer,Parser},
│                  Network.{RC2,URL},
│                  System.Concurrency.RC2, System.FFI.C.{Array,Ptr,Sizeof},
│                  System.GC.RC2, System.Linux.Epoll,
│                  System.Random.Xoroshiro{128PlusPlus,64StarStar},
│                  Text.Encoding.UTF8, Text.Regex.POSIX
├── src/           上記モジュールのIdris2ソース
├── support/c/     Cシム（libidris2rc2base.a）。prebuild / postinstallフックでビルド
├── doc/           主要コンポーネントの設計ノート（regex-posix.md、url.md ほか）
└── tests/         各モジュールの単体テスト（verify.sh）
```

上流の`base`や`contrib`に欠けている、または不十分な機能を補う基盤パッケージです。

- **ネットワーク**：バッファへのソケットIO（`Network.RC2`）、URLパーサ（`Network.URL`）。
- **並行処理・同期プリミティブ**：Haskell風の`MVar`、アトミックカウンタ（`Control.Concurrent.*`）、OSネイティブのスレッドとMutex（`System.Concurrency.RC2`）。
- **低レベルC連携とメモリ**：POSIX正規表現（`Text.Regex.POSIX`）、GMP整数演算（`Data.Integer.GMP`）、メモリバッファ、生UTF-8バイト列の変換（`Text.Encoding.UTF8`）、不透明なFFI値に対する参照カウントの明示的な操作（`System.GC.RC2`）。
- **コンパイラ解析基盤**：rc2が出力するIRダンプのパーサ（`Language.RCExpr.*`）。

モジュールごとの設計ノートは[`libs/rc2base/README.ja.md`](libs/rc2base/README.ja.md)を参照してください。

### `libs/control-async/`：タスクとノンブロッキングソケット

`Task`モナド（spawn/both/race、キャンセル、タイマー）と、`epoll`と任意で`io_uring`の上のスケジューラ、複数スレッドのタスクのための`Ref`/`MVar`/`Chan`、そのためのノンブロッキングソケット（`Control.Task*`、`Network.Async`）を備えます。`rc2base`に依存し、そこから切り出したパッケージです。`web`と`termui`はこの上で動きます。`libs/control-async/tests/verify.sh`（先に`libs/rc2base/tests/verify.sh`）でビルドし、プログラムは`-p control-async -p rc2base -p contrib`でコンパイルします。[`libs/control-async/README.ja.md`](libs/control-async/README.ja.md)を参照してください。

### `libs/web/`：HTTPクライアントとサーバ

`System.Linux.Epoll`上のHTTP/1.1サーバ（`Network.HTTP.Server`）と型安全なExpress風ルータ（`Network.HTTP.Route` / `Router`）、`Control.Task`のタスクで作った2つ目のサーバ（静的ファイル、CGI、リバースプロキシ、URL書き換え付き。`Network.Async.HTTP.*`）、libcurlのクライアントとOpenAI互換のチャットクライアント、OAuth 2.0（PKCE）ログイン（`Network.HTTP.Client.*`）を備えます。`rc2base`と`control-async`に依存し、`rc2base`から切り出したパッケージです。`libs/web/tests/verify.sh`（先に`libs/rc2base/tests/verify.sh`と`libs/control-async/tests/verify.sh`）でビルドし、プログラムは`-p web -p control-async -p rc2base -p contrib`でコンパイルします。[`libs/web/README.ja.md`](libs/web/README.ja.md)を参照してください。

### `libs/text-re2/`：Google RE2正規表現バインディング

```
libs/text-re2/
├── text-re2.ipkg   Idris2パッケージ: Text.Regex.RE2
├── src/            Idris2ソース
├── support/c/      C++シム（re2_util.cpp, libidris2rc2re2.so）
├── doc/regex.md    独立パッケージ化の設計背景
└── tests/          TestRE2.idr
```

線形時間でのマッチングを保証する、Googleの[RE2](https://github.com/re2)正規表現エンジンへのバインディングです。

`rc2base`から分離してあるのは、`rc2base`が依存するものを標準的なCツールチェーン（`gcc` / `ar`）だけに保つためです。RE2にはC++コンパイラ（`g++`）が必要で、Abseilの多数のフラグ（`pkg-config --libs re2`）も、専用の共有ライブラリ（`libidris2rc2re2.so`）にリンクする必要があります。通常の用途なら、`rc2base`の`Text.Regex.POSIX`が、外部依存のない正規表現マッチングを提供します。詳細は[`libs/text-re2/README.md`](libs/text-re2/README.md)を参照してください。

### その他のバインディング（notcurses, termui）

- **`libs/notcurses/`**：notcursesで高機能な端末UIを構築するための、rc2専用バインディング（`System.Notcurses`）。詳細は[`libs/notcurses/README.md`](libs/notcurses/README.md)を参照。

### `tools/rcexpr-lint/`：IR静的解析・バグ検出ツール

```
tools/rcexpr-lint/
├── RcexprLint.idr  CLI: .rcexprファイルを読み、異常とメトリクスを出力
├── Lint.idr        検査の中核となる規則
├── Metrics.idr     静的メトリクス（定義数、アロケーション数、クロージャ数、呼び出し数、dup/drop数）
├── README.md       検出範囲とレポートの見方
└── tests/          テストフィクスチャと verify.sh
```

IRダンプ（`--directive dumprcexpr`）から参照カウントの遷移を直接再導出し、コンパイル時にメモリ安全性を検証する静的解析ツールです。

- **検出する問題**：use-after-free（カウントが0に達した`Boxed`のローカル変数を読むこと）と、double-drop（すでに解放された変数を再度dropすること）を検出します。
- **開発の背景**：`Sink.idr`で、原因を突き止めにくい所有権バグに3回遭遇したことから開発されました。valgrindで欠陥を表に出すには、特定のテストを実行し、メモリを再利用させる必要があります。このツールは、コンパイルできるプログラムなら*どれでも*静的に検査できます。
- **静的メトリクス**：定義数、新規アロケーションとセルのその場再利用の件数、クロージャ数、関数呼び出し数、`dup`/`drop`の箇所数を報告します。最適化パスの評価に使えます。

```sh
source env.sh
rc2/build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr Prog.idr -o prog
tools/rcexpr-lint/build/exec/rcexpr-lint build/exec/prog.rcexpr
```

規則、終了コード、既知の制限（`case`の分岐で束縛されたフィールドは明示的な`Rep`を持たないため、`Boxed`と仮定される）は、[`tools/rcexpr-lint/README.md`](tools/rcexpr-lint/README.md)を参照してください。

### `tools/rcexpr-diff/`：IR差分比較ツール

2つの`.rcexpr` IRダンプを定義単位で比較します。変数の識別子を出現順に正規化し、コンパイラが生成した名前の連番を取り除きます。そのため、コンパイラのリビジョン間でどの定義が変わったかだけを、変数名の付け替えという連鎖的なノイズなしに取り出せます。詳細は[`tools/rcexpr-diff/README.md`](tools/rcexpr-diff/README.md)を参照してください。

---

## アーキテクチャと最適化パイプライン

### リポジトリ全体の構成

```
.
├── env.sh          生成された環境設定（ビルド・実行前にsourceする。gitignore対象）
├── gen-env.sh       env.shを再生成するスクリプト（Chez Schemeがscheme名で見つかることを確認する）
├── idris2-src/      github.com/idris-lang/Idris2のクローン（参照用・ブートストラップ用、gitignore対象）
├── install/         自前ビルドツールチェーンおよびrc2のローカルインストール先（gitignore対象）
├── libs/rc2base/    付属のネイティブC ABIサポートライブラリ
├── libs/control-async/  Taskモナド、スケジューラ、ノンブロッキングソケット（rc2baseが必要）
├── libs/web/        HTTPクライアントとサーバ（rc2baseとcontrol-asyncが必要）
├── libs/text-re2/   Google RE2正規表現バインディング
├── libs/notcurses/  notcursesバインディング（System.Notcurses）
├── tools/           IR検証・差分解析ツール（rcexpr-lint, rcexpr-diff）
└── rc2/             コアコンパイラ本体
```

### コンパイラ本体（`rc2/`）の内部構成

rc2は上流の構文木（case tree）を受け取り、独自のANF中間表現`RCExp`へ変換して、最適化パスを適用し、Cコードを出力します。

```
rc2/
├── rc2.ipkg           Idris2パッケージ設定。実行ファイル idris2-rc2 をビルド
├── src/Compiler/RC2/
│   ├── RCExp.idr        IR定義。ANF正規化され所有権注釈を持つ式構造
│   ├── Util.idr         依存の少ない共通ユーティリティ（import循環を防ぐ末端設計）
│   ├── RC.idr           case tree -> RCExp。Phase 1（正規化）、Phase 2（dup/drop/free挿入）
│   ├── Types.idr        native / boxed 表現の推論（Rep）
│   ├── InlineCExp.idr   リフティング前のプログラム全体インライン化
│   ├── LateInline.idr   ループ変換後のプログラム全体インライン化
│   ├── ArityRaiseCExp.idr, ArityRaise.idr
│   │                    world 引数の arity raising
│   ├── DeadArgs.idr     where 関数の未使用引数を削除
│   ├── LazyCaf.idr      トップレベル Delay をメモ化 CAF に変換
│   ├── LazyFold.idr     1回だけ force される遅延値を直接呼び出しに展開
│   ├── ConstFold.idr    ExtPrim、算術、比較、case、クロージャの定数畳み込み
│   ├── PushCon.idr      case 式をコンストラクタの末尾へ押し込み、畳み込みの機会を作る
│   ├── SpecClosure.idr  定数クロージャ・インターフェース辞書ごとの呼び出し先の特殊化
│   ├── Reuse.idr        コンストラクタセルのその場再利用
│   ├── ConAltNative.idr 分解フィールドのうち native として反復読取されるものをキャッシュ
│   ├── DeadVars.idr     参照されない分解済みフィールドを空化
│   ├── MutualLoop.idr   相互末尾再帰の関数を1つのループに統合
│   ├── Trmc.idr         Tail Recursion Modulo Constructor（TRMC）最適化
│   ├── ClosureCtx.idr   差分リストのパラメータをセルの連鎖として保持
│   ├── Loop.idr         自己末尾呼び出し -> goto 変換、ループ不変式の巻き上げ
│   ├── Sink.idr         分岐局所への let 沈め込み
│   ├── DualABI.idr      関数境界を跨ぐ二重呼び出し規約、構造体値返し
│   ├── DeadCode.idr     プログラム全体の mark-and-sweep デッドコード除去
│   ├── DupMerge.idr     同一変数に対する連続した RDup を一括化
│   ├── Emit.idr         RCExp -> C コードの機械的変換
│   ├── Emit/Util.idr        名前マングリング、リテラル・値出力、クロージャ、FFI 型変換
│   ├── Emit/Foreign.idr     %foreign / %export ラッパー生成と FFI マーシャリング
│   ├── ForeignSpec.idr      %foreign 規約文字列（C:/RefC:/RC2:/CExpr:）のパーサ
│   ├── Emit/ExternRefs.idr  インクリメンタルコンパイル用の前方宣言ウォーカー
│   ├── Pretty.idr       RCExp ダンプ出力（--directive dumprcexpr）
│   ├── CC.idr           C コンパイラ起動とリンク処理
│   └── RC2.idr          バックエンドエントリポイントとパイプライン登録
├── support/rc2/       ランタイムライブラリ（libidris2rc2.a）
├── doc/               各最適化パスの詳細な設計ノート（索引は AGENT.md 参照）
└── tests/             回帰テスト・ベンチマークスイート
```

### 主要な最適化パス（10の技術的柱）

rc2のパイプライン（`Compiler.RC2.RC2`の`toRCDefs`で組み立て）は、互いに独立してオン・オフできるパスで構成されています。

1. **独立したIRパスとしての参照カウント解析（`RC.idr`）**  
   RefCは、コード生成の途中で参照カウントを追跡します。rc2はこれと違い、C出力の前に所有権解析パス（Perceus / Koka方式）を実行します。`RCExp`には明示的な`RDup`、`RDrop`、`RFree`ノードが挿入されます。後続のパスは所有権を前提に最適化でき、`Emit.idr`は機械的なC出力に専念できます。
2. **native（unboxed）表現の推論（`Types.idr`, `DualABI.idr`）**  
   固定幅数値の中間値についてunboxed表現を推論し、Boxed / nativeの二重呼び出し規約（`DualABI`）で関数境界を越えて共有します。ループ内ではカウンタ変数をアンボックスのまま保ち（`Loop` / `MutualLoop`）、頻繁に読まれるフィールドはnative shadowとしてキャッシュします（`ConAltNative`）。
3. **コンストラクタのその場再利用（`Reuse.idr`）**  
   パターンマッチで値を分解し、直後に同じ形状のコンストラクタを再構築するとき、実行時に一意に所有されていれば（参照カウントが1）、既存のヒープセルを上書きして再利用します。再確保は行いません。
4. **ループ不変式の巻き上げとパラメータ除去（`Loop.idr`）**  
   反復のあいだ変化しないループパラメータは、ループのシグネチャから取り除きます。また、無条件に実行される先頭部分にある不変式は、ループの前へ巻き上げます。
5. **分岐局所への沈め込み（`Sink.idr`）**  
   `let`で束縛された計算が1つの分岐の中だけで使われる場合、その計算をその分岐へ直接沈め込みます。ほかの経路での無駄な計算を避けられます。
6. **プログラム全体のインライン化と定数畳み込み（`InlineCExp.idr`, `LateInline.idr`, `ConstFold.idr`）**  
   呼び出しを含まない小さな関数と、呼び出し箇所が1つだけの呼び出し先を展開します。定数の`ExtPrim`、算術、比較、分岐は畳み込みます。捕捉変数のない名前付きトップレベルクロージャは不変の定数に畳み込まれるため、インターフェース辞書レコードを完全に消去できます（最大4ラウンドの不動点計算）。
7. **クロージャ適用の高速パス（`support/rc2/idris2rc2_rt.c`）**  
   共有クロージャに最後の引数を適用するとき、一時的なクロージャを確保してすぐ破棄することはしません。対象の関数へ直接ディスパッチします。
8. **末尾再帰を超える高度な再帰最適化**  
   コンストラクタ直前の再帰（`x :: f xs`）は、セルの穴を埋めていく反復ループに変換します（Tail Recursion Modulo Constructor、`Trmc.idr`）。差分リストの累積引数（`c . (y ::)`）は、セルの連鎖として保持します（`ClosureCtx.idr`）。
9. **特殊化と呼び出し規約の再構成**  
   定数クロージャやインターフェース辞書を渡して呼ばれる関数は、複製して特殊化します（`SpecClosure.idr`）。そのほか、world引数のarity raising（`ArityRaise.idr`）、`where`関数の未使用引数の削除（`DeadArgs.idr`）、4フィールド以下のコンストラクタをヒープ確保ではなくC構造体の値として返す処理（`DualABI.idr`）を行います。
10. **実行時コストの極小化（即値整数とハイブリッド参照カウント）**  
    62ビットに収まる整数（`Int`, `Int64`, `Bits64`, `Integer`）は、ヒープ確保なしでポインタのワードに直接格納します。参照カウント操作は、第2スレッドが実際に生成されるまで、通常の非アトミック命令のままです。

---

## 上流RefCとの意図的な違い・改善点

rc2は、上流RefCの重大なバグと欠落を修正し、Chez Schemeバックエンドと意味論を揃えています。

### 1. 完全なUnicodeスカラー値に対応したChar

上流RefCは、ランタイム全体で`Char`を1バイトのC `char`に切り詰めるため、ASCII範囲外の文字が壊れます。rc2は、32ビットのUnicodeスカラー値（`0..0x10FFFF`）をそのまま保持します。範囲外の値は安全にNULへ変換します。

例外として、`CFStruct`の`Char`として束縛されたフィールドだけは、1バイトの`char`のままです。ネイティブCライブラリの構造体とバイト単位でレイアウトを一致させるためです。

### 2. コードポイント準拠とNUL終端安全なString

RefCは文字列をバイト単位で処理しますが、rc2は言語仕様どおり、コードポイント単位でインデックス指定、切り出し、長さの計算を行います（不正なバイト列は安全に`U+FFFD`へデコードします）。文字列はUTF-8のバイトバッファとして保持するため、`strIndex`のようなコードポイント単位の操作の計算量はO(N)です。

また、上流RefCは文字列を単なる`char *`で表すため、最初に現れる埋め込みNUL（`\0`）で切り捨てられます。rc2の`IDRIS2RC2_String`は、ヘッダのパディングに明示的なバイト長（`len`）を持ちます。そのため、埋め込みNULを含むバイト列も、そのまま往復でき、`memcmp`で正確にパターンマッチできます（標準のC FFI境界を`char *`として越えるときは、Cの規則どおりNULで終端されます）。

### 3. 本物のマルチスレッド並行処理（pthread）

上流RefCは、`prim__fork`を`exit(0)`で済ませるスタブにしています。また`System.Concurrency`のプリミティブは、Scheme専用の外部宣言にしています。

rc2は、本物のデタッチされたPOSIXスレッド（`pthread`）を起動します。さらに`%foreign_impl`で、上流の宣言（`Mutex`, `Condition`, `Semaphore`, `Barrier`, `Channel`）を本物のpthreadオブジェクトに対応付けます（`libs/rc2base`の`System.Concurrency.RC2`をimportするだけで使えます）。join可能なスレッドのプリミティブ（`forkJoin`, `join`, `JoinHandle`）も追加しています。`Channel`の非ブロッキング操作は、`Prelude.Maybe`の`Just`コンストラクタがtag=1 / arity=1であることを前提にしています。

### 4. ネイティブC ABIとの直接連携（%export）

上流RefCは`%export`プラグマを完全に無視します。

rc2は、本物のネイティブC ABIラッパーを生成します。引数と戻り値のマーシャリングとアンボックス化の対象は、スカラー型、`Ptr` / `AnyPtr`、`GCPtr`（引数のみ）、GMP `Integer`、文字列、構造体です。素のCプログラムは、Idrisのランタイムヘッダをリンクしなくても、エクスポートされたIdris関数を直接呼び出せます。

### 5. プロセスのライフサイクルとロケール非依存な数値書式化

rc2が生成する`main()`は、ライフサイクルフック`idris2rc2_rtInit()`と`idris2rc2_rtFinish()`を呼び出します。`rtInit`は`setlocale(LC_ALL, "")`を呼ぶので、POSIX正規表現関数はUTF-8環境を正しく解釈します。`rtFinish`は`fflush(NULL)`で標準ストリームをフラッシュします。

`Double <-> String`の変換には、自前の10進変換エンジンを使います。出力は正確で、往復可能な最短の文字列です。ロケールの小数点記号（`LC_NUMERIC`）にはまったく依存しません。

### 6. 正しい意味論を保証するCAFとLazy / Infのメモ化

上流RefCでは、引数0個のトップレベル定義（CAF）が参照のたびに再評価されていました。たとえば`counter = unsafePerformIO (newIORef 0)`は、アクセスのたびに別々のIORefインスタンスを生成していました。rc2は、定数畳み込みのあとに`RMemoize` IRノードを挿入します。このノードが、結果をアトミックに評価・キャッシュし、すべての参照で共有します。これにより、Chez Schemeと同じ`0 1 2`という期待どおりの出力が得られます。

同様に、上流RefCは`Delay` / `Force`を通常のクロージャに変換していたため、forceのたびに遅延された計算が再実行されていました。rc2は専用の`RDelay`ノードと`RForce`ノードを保持し、最初の評価結果を`idris2rc2_force`でキャッシュします。

### 7. `%foreign`の対象としてのC式（`CExpr:`）
`%foreign "CExpr:abs($1),libc,stdlib.h"`は、宣言を関数名ではなく、C式や定数（`O_CREAT`のようなマクロ）に束縛します。そのため、Cシムは不要です。`$1`, `$2`, ...は引数で、括弧で囲んで置換されます。`Integer`を返す宣言では、`$r`がGMPの出力パラメータになります（`"CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"`）。GMPの関数も、シムなしで束縛できます。

ヘッダのオプションには、`;`で区切って複数のヘッダを指定できます（`fcntl.h;sys/stat.h`。RefCは全体を1つの名前として読みます）。`CExpr:`は、rc2が扱うタグの中で最優先であり、ほかのバックエンドは無視します。詳細は[`rc2/doc/ffi-cexpr.md`](rc2/doc/ffi-cexpr.md)を参照してください。

---

## %cg rc2ディレクティブによるチューニング

rc2は、ソースファイル中の`%cg rc2 <directive>`プラグマと、コマンドラインの`--directive VALUE`フラグを受け付けます。

- **パスの切り替え（A/Bテスト・診断用）**：`--directive noloop`や`--directive noconstfold`のように、最適化の段階を個別に無効にできます。
- **デバッグダンプ**：`dumprcexpr`、`dumpdualabi`、`dumpcc`で、人間が読める表現を出力します。
- **Cコードの直接取り込み**：`extraRuntime=<path>`（Cソースファイルを含む）または`inlineRuntime=<code>`（インラインのCスニペット）で、外部のCコードを直接組み込めます。CFLAGSやLDFLAGSを変更する必要はありません。

全ディレクティブの一覧と設計の背景は、[`rc2/doc/directives.md`](rc2/doc/directives.md)を参照してください。

---

## インクリメンタルコンパイル（--inc rc2）

RefCはインクリメンタルビルドに対応しておらず、コンパイルのたびに全体を再ビルドします。rc2は、上流の`Codegen.incCompileFile` / `incExt`の仕組みを実装しています。

```sh
idris2-rc2 --cg rc2 --inc rc2 -o program Program.idr
```

- 各モジュールは、個別の`.o`オブジェクトファイルに一度だけコンパイルされます。ソースが変わっていなければ、既存のオブジェクトを再利用します。
- `prelude`, `base`, `linear`, `contrib`, `network`の合計272モジュールで、インクリメンタルビルド用のシンボルが欠けていないことを確認済みです。
- **現在の制限**：C構造体のアクセサ（`getField` / `setField` / `Struct`）はプログラム全体のインライン化を必要とするため、現時点では`--inc rc2`と併用できません（リンク時に未定義参照エラーになります。プログラム全体を一括でビルドする場合は影響を受けません）。ビルドを十分に高速化するには、標準ライブラリをあらかじめ一度`--inc rc2`で再ビルドしておく必要があります。詳細は[`rc2/doc/incremental-compile.md`](rc2/doc/incremental-compile.md)を参照してください。

---

## テストと品質保証

### 一括回帰テスト（verify.sh）

```sh
cd rc2/tests
source ../../env.sh
./verify.sh
```

`verify.sh`は、次のテストをまとめて実行します。

1. `idris2-rc2`とランタイムライブラリをビルドします。
2. 上流RefCから移植した回帰テストスイート（`rc2/tests/refc-suite/`）を実行します。
3. 手書きのスモークテスト55個をコンパイルし、保存済みの`.expected`出力と突き合わせます。
4. リーク検出の対象テストを`valgrind --leak-check=full`で実行します。
5. マルチスレッドのテストを、`tsan.sh`経由で**ThreadSanitizer（TSan）**の下で実行します。
6. すべてのスモークテストのIRダンプを`tools/rcexpr-lint`で検査します。

**主なオプション**
- `--skip-build`：コンパイラの再ビルドを省略します。
- `--no-valgrind`：valgrindによる検査を省略して、高速に実行します。
- `--valgrind-all`：すべてのテストをvalgrindの下で実行します。
- `--no-refc-suite` / `--no-tsan`：特定のテストスイートを除外します。
- `--directive VALUE`：コンパイラにディレクティブを渡します（例：`--directive noloop`）。
- `--regen-expected`：スモークテストの期待出力を再生成します。
- 環境変数`TEST_TIMEOUT`（既定値は60秒。valgrind / TSan実行時は10倍）。

### 出力を変えない変更の検証（snapshot.sh, nopass.sh）

コンパイラの出力を完全に保つべきリファクタリングや最適化では、次のスクリプトを使います。

- `snapshot.sh save DIR` / `snapshot.sh diff DIR`：実行間で、生成されたIRダンプとC出力をバイト単位で比較します。
- `nopass.sh`：最適化の段階を1つずつ無効にしてスモークテストを実行し、パス間の隠れた依存関係を明らかにします。

### 性能測定ベンチマーク（bench.sh）

```sh
cd rc2/tests
./bench.sh
```

`rc2/tests/Bench*.idr`を、`idris2-rc2`と上流の`idris2 --cg refc`の両方でコンパイルして時間を測り、実時間での速度向上比を報告します（`--runs N`で反復回数を指定し、`--missing-containers`で外部コンテナのベンチマークを追加します）。結果と測定方法は[`rc2/BENCHMARKS.md`](rc2/BENCHMARKS.md)に記録されています。

### IRリンター単体テスト

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

---

## 現状とサポート範囲

rc2は、実運用に耐える水準の外部Cコード生成バックエンドとして動作します。

### 検証済み機能

- **メモリ・値表現の最適化**：コンストラクタのその場再利用、native表現の推論と二重呼び出し規約（`DualABI`）、C構造体による値返し、重複した参照カウント操作の統合（`DupMerge`）、即値整数、ハイブリッド参照カウント。
- **制御フロー・最適化パス**：自己末尾呼び出しと相互末尾呼び出しのループ化とループ不変式の巻き上げ、Tail Recursion Modulo Constructor（TRMC）、分岐局所へのlet沈め込み、プログラム全体のインライン化、定数畳み込み、デッドコード除去、クロージャと辞書の特殊化、world引数のarity raising。
- **意味論の修正とビルド機能**：CAFとLazy / Infのアトミックなメモ化、インクリメンタルコンパイル（`--inc rc2`）。
- **標準ライブラリのサポート**：`Data.Buffer`、`System.Clock`、標準の`network`パッケージをネイティブにサポートします。

### 今後の課題とトレードオフ

検討中の課題（末尾委譲呼び出しのネイティブ化、小型オブジェクト用アロケータなど）と、意図的に選んだ設計上のトレードオフの詳細は、[`TODO.md`](TODO.md)に記録しています。設計の背景とバグ修正の経緯は、[`rc2/doc/`](rc2/doc/)にあります。
