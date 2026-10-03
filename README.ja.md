# idris2-rc-cg (rc2)

*[English](README.md)*

idris2-rc-cg（rc2）は、依存型プログラミング言語[Idris 2](https://github.com/idris-lang/Idris2)のための高速で堅牢な、独立した外部C言語コード生成バックエンドです。

Idris 2公式のCバックエンド（RefC）が持つ基本設計（値の表現、参照カウント、クロージャ機構）を手本としつつ、Perceus方式の参照カウント最適化パイプライン、POSIXスレッドによる本格的なマルチスレッド並行処理、完全なUnicode準拠、インクリメンタルコンパイル、そして実用的なネイティブC ABI連携ツールキットを提供します。

上流のIdris 2本体には一切変更を加えず、参照用リポジトリを横に配置した状態で、完全に独立した実行ファイル`idris2-rc2`としてビルド・利用できます。

---

## 目次

- [主な特徴とハイライト](#主な特徴とハイライト)
- [クイックスタート](#クイックスタート)（[環境準備](#1-環境変数の準備) / [ビルド](#2-rc2本体のビルドとインストール) / [ライブラリ導入](#3-サポートライブラリrc2baseのインストール) / [コンパイル実行](#4-プログラムのコンパイルと実行) / [性能計測](#ビルド時の性能計測--timing)）
- [付属エコシステムと開発ツール](#付属エコシステムと開発ツール)（[rc2base](#libsrc2baseネイティブc-abiツールキット) / [text-re2](#libstext-re2google-re2正規表現バインディング) / [io_uring・notcurses](#その他のバインディングio_uring-notcurses) / [rcexpr-lint](#toolsrcexpr-lintir静的解析バグ検出ツール) / [rcexpr-diff](#toolsrcexpr-diffir差分比較ツール)）
- [アーキテクチャと最適化パイプライン](#アーキテクチャと最適化パイプライン)（[リポジトリ構成](#リポジトリ全体の構成) / [コンパイラ内部構成](#コンパイラ本体rc2の内部構成) / [最適化パス](#主要な最適化パス10の技術的柱)）
- [上流RefCとの意図的な違い・改善点](#上流refcとの意図的な違い改善点)（[Char](#1-完全なunicodeスカラー値に対応したchar) / [String](#2-コードポイント準拠とnul終端安全なstring) / [pthread](#3-本物のマルチスレッド並行処理pthread) / [%export](#4-ネイティブc-abiとの直接連携export) / [ライフサイクル](#5-プロセスのライフサイクルとロケール非依存な数値書式化) / [CAF・Lazyメモ化](#6-正しい意味論を保証するcafとlazy--infのメモ化)）
- [%cg rc2ディレクティブによるチューニング](#cg-rc2ディレクティブによるチューニング)
- [インクリメンタルコンパイル（--inc rc2）](#インクリメンタルコンパイル--inc-rc2)
- [テストと品質保証](#テストと品質保証)（[verify.sh](#一括回帰テストverifysh) / [snapshot・nopass](#出力を変えない変更の検証snapshotsh-nopasssh) / [bench.sh](#性能測定ベンチマークbenchsh) / [IRリンター](#irリンター単体テスト)）
- [現状とサポート範囲](#現状とサポート範囲)

---

## 主な特徴とハイライト

### 独立したIRパスによる高精度な参照カウント（Perceus / Koka方式）
RefCのようなCコード出力時のアドホックな参照カウント処理を排し、ANF正規化された専用の中間表現`RCExp`上で独立した所有権解析を実施。明示的な`RDup`、`RDrop`、`RFree`ノードを挿入して厳密に管理します。

### コンストラクタのその場再利用（In-place Reuse）
パターンマッチで分解した値が実行時に一意に所有（参照カウント1）されている場合、ヒープ領域を解放・再確保することなく、既存のセルをその場で更新して再利用するのが特徴です。

### ネイティブ型推論（Unboxing）と二重ABI（Dual ABI）
固定幅の数値をunboxedなnative値として推論し、自己末尾再帰・相互末尾再帰ループ全体でアンボックス状態を保持。さらに関数境界を越えてnative値を渡せる二重呼び出し規約や、C構造体による値返し（Struct Return）もサポートしています。

### 本物のマルチスレッド並行処理（POSIX Threads）
上流RefCのスタブ（`exit(0)`）を排し、本物の`pthread`を起動。第2スレッドが生成される瞬間までアトミック操作を行わないハイブリッド参照カウントを採用し、シングルスレッド性能を犠牲にしません。

### 完全なUnicode準拠とNUL安全な文字列
`Char`は32ビットのUnicodeスカラー値を完全に保持し、`String`はChez Schemeと同様にコードポイント単位で動作します。またヘッダに明示的な長さ情報（`len`）を持つため、埋め込みNUL（`\0`）を含む文字列も安全に取り扱えます。

### ネイティブC ABIラッパーの自動生成（`%export`）
Idris 2の関数を外部Cプログラムから直接呼べるラッパー関数を自動生成。型マーシャリングを内部で行うため、C側はIdris 2ランタイムの内部構造を意識せずに呼び出せます。

### インクリメンタルコンパイル（`--inc rc2`）
モジュール単位で個別の`.o`ファイルにコンパイルして再利用するため、ビルド時間を大幅に短縮できます。

### 充実したネイティブツールキット
Epollベースの高速HTTP/1.1サーバやMVarを含む`libs/rc2base`、Google RE2正規表現バインディング、静的IR検査ツール`tools/rcexpr-lint`などを標準で同梱。実用的なネイティブ開発を強力に後押しします。

---

## クイックスタート

### 1. 環境変数の準備

リポジトリをクローンしたら、まず環境設定スクリプトを生成してシェルに読み込みます。

```sh
./gen-env.sh
source env.sh
```

`gen-env.sh`は、自前ビルドの`install/bin`コンパイラを指す`PATH`やサポートライブラリのパスを`env.sh`として出力します（PATH上にChez Schemeが`scheme`という名前で必要です）。  
なお、`idris2-src/`は`https://github.com/idris-lang/Idris2.git`のクローンであり、参照資料および自前ビルドidris2のブートストラップ元として機能します（編集は行いません）。`install/`はビルド成果物のローカルインストール先です。

### 2. rc2本体のビルドとインストール

```sh
cd rc2
source ../env.sh
nix-shell -p gcc gmp pkg-config --run 'idris2 --build rc2.ipkg && idris2 --install rc2.ipkg'
```

`source ../env.sh`により、`PATH`先頭の自前ビルド`install/bin/idris2`が使われます。このコンパイラは`install/`プレフィックスを初めから保持しているため、`IDRIS2_PREFIX`のexportは不要です。  
（参考：nixpkgsの`idris2`を使ってビルドする場合は、nix storeが読み取り専用であるため、`export IDRIS2_PREFIX="$(cd .. && pwd)/install"`を明示的に指定する必要があります）

ビルドにより実行ファイル`rc2/build/exec/idris2-rc2`が生成されます。rc2でコンパイルされたプログラムにリンクされるランタイムライブラリ（`libidris2rc2.a`）は`rc2/support/rc2/`にあり、`rc2.ipkg`のフックによって自動的にコンパイル・配置されます（`make -C support/rc2 && make -C support/rc2 install`で単独再ビルドも可能です）。

### 3. サポートライブラリ（rc2base）のインストール

実用的なプログラムの多くでは、付属のサポートライブラリ[`libs/rc2base/`](#libsrc2baseネイティブc-abiツールキット)が必要になります。上流の`%foreign`プリミティブのうち、Cバックエンドが存在しない機能（GMPによる`Integer`演算、`Data.Buffer`の一部、`Data.Double`の定数、`System.Random`など）を補完するためです。

```sh
cd ..
source env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)
```

自前ビルドの`idris2`は初めの設定で自身のインストール先（`install/`）を参照するため、インストール後に環境変数を追加設定する必要はありません。

### 4. プログラムのコンパイルと実行

Idris 2ソースコードをrc2バックエンドでコンパイルします。

```sh
nix-shell -p gcc gmp pkg-config --run \
  './rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base Program.idr -o program'
./program
```

生成されるCコードは、初期設定でランタイムと同じ`-O2`で最適化されます。最適化を無効化したい場合は、`CFLAGS=-O0`や`IDRIS2_CFLAGS`を指定してください。

### ビルド時の性能計測（--timing）

上流Idris 2の`--timing N`フラグを利用して、コード生成パイプラインの所要時間を確認できます。

- `--timing 1` では、コード生成全体の合計時間（"Code generation overall"）を表示します。
- `--timing 2` では、rc2のパイプライン段階ごとの内訳（`rc2: <stage>`）を表示します（inline, RC normalize, ConstFold, CAF memoization, RC annotate/reuse/ConAltNative, mutual loop, loop conversion, sink, dual ABI, dead-code elimination, dup merge, C generation, C compile, C link）。
- `--timing 3` では、処理の重い段階（inlineやloop conversion）の下位フェーズまで掘り下げて表示します。
- 後述の`--directive no<stage>`で無効化された段階は、計測行そのものが出力されなくなります。

---

## 付属エコシステムと開発ツール

rc2リポジトリには、実用的なアプリケーション開発とコンパイラ自身の品質を支えるライブラリや専用ツールが同梱されています。

### `libs/rc2base/`：ネイティブC ABIツールキット

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
├── support/c/     Cシム（libidris2rc2base.a）
├── doc/           規模の大きい機能の設計ノート（http-router.md、http-server.md等）
└── tests/         各モジュールの単体テスト（verify.sh）
```

上流の`base`や`contrib`に欠落しているか、不十分な機能を補うrc2専用の基盤パッケージです。

- **高速Web・ネットワーク**：`System.IO.Epoll`を基盤とするイベント駆動型HTTP/1.1サーバ（`Network.HTTP.Server`）、型安全なExpress風ルータ（`Network.HTTP.Route` / `Router`）、URLパーサ（`Network.URL`）。
- **並行処理・同期プリミティブ**：Haskell風の`MVar`、アトミックカウンタ（`Control.Concurrent.*`）、OSスレッド・Mutex（`System.Concurrency.RC2`）。
- **低レベルC連携とメモリ**：POSIX正規表現（`Text.Regex.POSIX`）、GMP整数演算（`Data.Integer.GMP`）、メモリバッファ、生UTF-8バイト列変換（`Text.Encoding.UTF8`）、参照カウントの直接操作（`System.GC.RC2`）。
- **コンパイラ解析基盤**：rc2のIRダンプをパースする構文解析器（`Language.RCExpr.*`）。

詳細は[`libs/rc2base/README.md`](libs/rc2base/README.md)を参照してください。

### `libs/text-re2/`：Google RE2正規表現バインディング

```
libs/text-re2/
├── text-re2.ipkg   Idris2パッケージ: Text.Regex.RE2
├── src/            Idris2ソース
├── support/c/      C++シム（re2_util.cpp, libidris2rc2re2.so）
├── doc/regex.md    独立パッケージ化の設計背景
└── tests/          TestRE2.idr
```

高速かつ線形時間でのマッチングを保証するGoogleの[RE2](https://github.com/re2)エンジンへのバインディングです。  
`rc2base`を標準的なCツールチェーン（`gcc` / `ar`）だけでビルドできるようにするため、C++ツールチェーンと多数のAbseilライブラリフラグを要するRE2は独立した共有ライブラリ（`libidris2rc2re2.so`）として分離されています（通常の正規表現用途であれば、外部依存のない`Text.Regex.POSIX`で十分対応可能です）。

詳細は[`libs/text-re2/README.md`](libs/text-re2/README.md)を参照してください。

### その他のバインディング（io_uring, notcurses）

- **`libs/iouring/`**：Linuxの高性能非同期I/Oフレームワークio_uringのバインディング（`System.IO.Uring`）。詳細は[`libs/iouring/README.md`](libs/iouring/README.md)を参照。
- **`libs/notcurses/`**：端末UIを構築するnotcursesのrc2専用バインディング（`System.Notcurses`）。詳細は[`libs/notcurses/README.md`](libs/notcurses/README.md)を参照。

### `tools/rcexpr-lint/`：IR静的解析・バグ検出ツール

```
tools/rcexpr-lint/
├── RcexprLint.idr  CLI: .rcexprファイルを読み、異常とメトリクスを出力
├── Lint.idr        検査本体（規則の詳細はモジュール内注記参照）
├── Metrics.idr     静的メトリクス（定義数、アロケーション数、dup/drop数等）
├── README.md       検出仕様とレポートの見方
└── tests/          テストフィクスチャと verify.sh
```

rc2が`--directive dumprcexpr`で出力するIRダンプから参照カウントの遷移を再導出し、コンパイル時にメモリ安全性を静的検証するツールです。

- **検出する問題**：所有権が尽きた変数を再読込するuse-after-freeや、すでに解放された変数を再度破棄するdouble-dropを検出します。
- **開発の背景**：最適化パス（`Sink.idr`）の開発中に混入した発見困難な所有権バグを、valgrindなどの動的検査に頼らず、あらゆるプログラムのIRに対して静的に網羅検出するために作られました。
- **静的メトリクスの出力**：アロケーション種別（新規確保 vs セル再利用）、クロージャ数、呼び出し数、`dup`/`drop`数などを集計し、最適化パスの効果を比較できます。

```sh
source env.sh
rc2/build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr Prog.idr -o prog
tools/rcexpr-lint/build/exec/rcexpr-lint build/exec/prog.rcexpr
```

詳細は[`tools/rcexpr-lint/README.md`](tools/rcexpr-lint/README.md)を参照してください。

### `tools/rcexpr-diff/`：IR差分比較ツール

2つの`.rcexpr` IRダンプを定義単位で比較するツールです。出現順に変数をナンバリングし直し、生成名に含まれる自動採番カウンタを取り除くことで、コンパイラの修正によって真に変化が生じた定義だけを正確に特定できます。

詳細は[`tools/rcexpr-diff/README.md`](tools/rcexpr-diff/README.md)を参照してください。

---

## アーキテクチャと最適化パイプライン

### リポジトリ全体の構成

```
.
├── env.sh          生成された環境設定（rc2のビルド・実行前にsourceする）（gitignore対象）
├── gen-env.sh       env.shを再生成するスクリプト（Chez Schemeがscheme名で必要）
├── idris2-src/      github.com/idris-lang/Idris2のクローン（参照用・ブートストラップ用、gitignore対象）
├── install/         自前ビルドツールチェーンおよびrc2のローカルインストール先（gitignore対象）
├── libs/rc2base/    付属のネイティブC ABIサポートライブラリ
├── libs/text-re2/   Google RE2正規表現バインディング
├── libs/iouring/    io_uringバインディング（System.IO.Uring）
├── libs/notcurses/  notcursesバインディング（System.Notcurses）
├── tools/           IR検証・差分解析ツール（rcexpr-lint, rcexpr-diff）
└── rc2/             コアコンパイラ本体
```

### コンパイラ本体（`rc2/`）の内部構成

rc2は上流の構文木（case tree）を受け取り、独自のANF中間表現`RCExp`を経由して最適化を施したのち、Cコードを出力します。

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
│   ├── ConstFold.idr    ExtPrim、算術、比較、定数分岐、不変クロージャの定数畳み込み
│   ├── PushCon.idr      case 式をマッチ対象の末尾へ押し込み、畳み込みを促進
│   ├── SpecClosure.idr  定数クロージャ・インターフェース辞書ごとの呼び出し先複製（特殊化）
│   ├── Reuse.idr        コンストラクタのその場再利用（In-place Reuse）
│   ├── ConAltNative.idr 分解フィールドのうち native として反復読取されるものをキャッシュ
│   ├── DeadVars.idr     参照されない分解済みフィールドを空化
│   ├── MutualLoop.idr   相互末尾再帰を1つの自己末尾再帰関数に統合
│   ├── Trmc.idr         Tail Recursion Modulo Constructor（TRMC）最適化
│   ├── ClosureCtx.idr   差分リストのパラメータをセルの連鎖として保持
│   ├── Loop.idr         自己末尾呼び出し -> goto 変換、ループ不変式の巻き上げ
│   ├── Sink.idr         分岐局所への let 沈め込み
│   ├── DualABI.idr      関数境界を跨ぐ二重呼び出し規約、構造体値返し
│   ├── DeadCode.idr     プログラム全体の mark-and-sweep デッドコード除去
│   ├── DupMerge.idr     直線区間内の同一変数に対する複数 RDup を一括呼び出しに統合
│   ├── Emit.idr         RCExp -> C コード機械的変換
│   ├── Emit/Util.idr        名前マングリング、リテラル・値出力、クロージャ、FFI 型変換
│   ├── Emit/Foreign.idr     %foreign / %export ラッパー生成と FFI マーシャリング
│   ├── Emit/ExternRefs.idr  インクリメンタルコンパイル用 extern 前方宣言生成
│   ├── Pretty.idr       RCExp ダンプ出力（--directive dumprcexpr）
│   ├── CC.idr           C コンパイラ起動とリンク処理
│   └── RC2.idr          バックエンドエントリポイントとパイプライン統合
├── support/rc2/       ランタイムライブラリ（libidris2rc2.a）
├── doc/               各最適化パスの詳細な設計ノート（索引は AGENT.md 参照）
└── tests/             回帰テスト・ベンチマークスイート
```

### 主要な最適化パス（10の技術的柱）

rc2のパイプライン（`Compiler.RC2.RC2`の`toRCDefs`で組み立て）は、互いに独立してオン・オフ可能な最適化パスで構成されています。

1. **独立したIRパスとしての参照カウント解析（`RC.idr`）**  
   上流RefCがC出力処理の途中で参照カウントを埋め込むのに対し、rc2はCコード生成の前に独立した所有権解析パス（Perceus / Koka方式）を実行します。`RCExp`に明示的な`RDup`、`RDrop`、`RFree`ノードを挿入し、後続のパスはこの判断との整合性を維持しながら最適化を行います。`Emit.idr`は純粋に機械的なC出力に専念します。
2. **native（unboxed）表現の推論（`Types.idr`, `DualABI.idr`）**  
   固定幅数値の中間値を推論し、Boxed / nativeの二重呼び出し規約（`DualABI`）によって関数境界を越えてネイティブ値のまま受け渡します。ループ内ではカウンタ変数をアンボックスのまま保持し（`Loop` / `MutualLoop`）、分解フィールドの頻出アクセスはnative shadowとしてキャッシュします（`ConAltNative`）。
3. **コンストラクタのその場再利用（`Reuse.idr`）**  
   パターンマッチで値を分解し、直後に同じ形状のコンストラクタを再構築する際、実行時の一意所有（参照カウント1）が確認できれば、ヒープ確保を行わず元のメモリ領域をその場で上書きして再利用します。
4. **ループ不変式の巻き上げとパラメータ除去（`Loop.idr`）**  
   反復の過程で変化しないループ引数はループの引数リストから完全に取り除きます。また、ループ先頭で必ず実行される不変式はループ手前に一度だけ計算するように巻き上げます。
5. **分岐局所への沈め込み（`Sink.idr`）**  
   `let`で束縛された値が後続の分岐の特定分岐（1つの枝）でしか使われない場合、その束縛計算を該当する分岐の中へ沈め込み、不要な計算を回避します。
6. **プログラム全体のインライン化と定数畳み込み（`InlineCExp.idr`, `LateInline.idr`, `ConstFold.idr`）**  
   呼び出しを含まない小さな関数や1箇所でのみ呼ばれる関数を展開し、定数`ExtPrim`、算術・比較、定数分岐を畳み込みます。捕捉変数のないクロージャは不変の定数として畳み込まれるため、インターフェース辞書レコードをコンパイル時に丸ごと消去できます（最大4ラウンドの不動点計算）。
7. **クロージャ適用の高速パス（`support/rc2/idris2rc2_rt.c`）**  
   共有クロージャへの最後の引数適用時、一時的なクロージャを確保してすぐ破棄する無駄を省き、対象関数へ直接ディスパッチします。
8. **末尾再帰を超える高度な再帰最適化**  
   コンストラクタ直前の再帰（`x :: f xs`）をセルの穴埋めループに変換するTRMC（`Trmc.idr`）や、差分リスト累積引数（`c . (y ::)`）をセルの連鎖として保持する`ClosureCtx.idr`を実装しています。
9. **特殊化と呼び出し規約の再構成**  
   定数クロージャやインターフェース辞書が渡される呼び出し先を関数単位で複製・特殊化します（`SpecClosure.idr`）。さらにworld引数のarity raising（`ArityRaise.idr`）、未使用引数削除（`DeadArgs.idr`）、4フィールド以下のコンストラクタをヒープ確保ではなくC構造体の値として返すStruct Return（`DualABI.idr`）などを適用します。
10. **実行時コストの極小化（即値整数とハイブリッド参照カウント）**  
    62ビットに収まる整数（`Int`, `Int64`, `Bits64`, `Integer`）はポインタのワード値に直接埋め込んでヒープ確保を回避します。参照カウントは、第2スレッドが生成されるまで非アトミック命令で操作されます。

---

## 上流RefCとの意図的な違い・改善点

rc2は、上流RefCの不十分な仕様を修正し、Chez Schemeバックエンドと同等の厳密な意味論と高い信頼性を備えています。

### 1. 完全なUnicodeスカラー値に対応したChar

上流RefCでは、ランタイム全体で`Char`を1バイトのC `char`に切り捨てており、ASCII範囲外の文字が破壊されていました。これに対し、rc2は32ビットのUnicodeスカラー値（`0..0x10FFFF`）を完全に保持し、不正な範囲の値も安全にNULへマッピングして意図しない別文字化を防ぎます。  
なお、C言語ライブラリの構造体とバイト単位でレイアウトを合わせる必要があるため、例外として`CFStruct`の`Char`フィールドのみCの1バイト`char`を維持する設計です。

### 2. コードポイント準拠とNUL終端安全なString

上流RefCは文字列操作をバイト単位で行いますが、rc2は仕様通りUnicodeコードポイント単位で走査・切り出しを行います（不正バイト列はUnicode標準の置換文字`U+FFFD`にデコード）。UTF-8バイト列を維持したまま走査するため、`strIndex`等はO(N)となります。

また、上流RefCの文字列は単なる`char *`であり、途中にNULがあるとそれ以降が切り捨てられる問題がありました。rc2の`IDRIS2RC2_String`はヘッダのパディングを活用して明示的なバイト長フィールド（`len`）を保持しており、`\0`を含む文字列のパターンマッチや結合を正しく扱えます（C FFI境界を跨ぐ場合のみ通常のC文字列の制約を受けます）。

### 3. 本物のマルチスレッド並行処理（pthread）

上流RefCの`prim__fork`実装は`exit(0)`を呼ぶだけのスタブであり、マルチスレッドが全く機能しませんでした。また標準ライブラリの`System.Concurrency`宣言もScheme専用の外部定義となっていました。

rc2では、ランタイムで本物のデタッチされた`pthread`を起動します。さらに`%foreign_impl`プラグマを用いて、上流コードに一切手を加えることなく、`Mutex`, `Condition`, `Semaphore`, `Barrier`, `Channel`を本物のpthreadオブジェクトとして完全実装しています（`libs/rc2base`の`System.Concurrency.RC2`をimportするだけで透過的に機能します）。加えて、上流に存在しないjoin可能なスレッド機能（`forkJoin` / `join` / `JoinHandle`）も提供します。`Channel`の非ブロッキング取得等では、固定ライブラリ型である`Prelude.Maybe`の`Just`（tag=1, arity=1）を安全に再構築します。

### 4. ネイティブC ABIとの直接連携（%export）

上流RefCでは`%export`ディレクティブが無視され、C言語からIdris関数を呼び出す手段がありませんでした。

rc2は、ネイティブC呼び出し規約に準拠したCラッパー関数を自動生成します。スカラー型、`Ptr` / `AnyPtr`、`GCPtr`（引数のみ）、GMP `Integer`、`String`、構造体ポインタを相互に自動マーシャリング（boxing / unboxing）するため、素のCプログラムからIdris 2ランタイムの内部構造を意識せずに通常のエクスポート関数として直接呼び出せます。

### 5. プロセスのライフサイクルとロケール非依存な数値書式化

rc2の`main()`は、前後に`idris2rc2_rtInit()`と`idris2rc2_rtFinish()`を呼び出します。`setlocale(LC_ALL, "")`によって環境のUTF-8ロケールをlibcへ反映し、POSIX正規表現などの正常なUTF-8動作を保証したうえで、終了時には`fflush(NULL)`を呼び出す設計です。

また、`Double <-> String`変換は自前の10進変換エンジンで行われます。RefCのようにロケールによって小数点記号が変わったり桁数が6桁に制限されたりせず、常に最短かつ正確な表記を出力します。

### 6. 正しい意味論を保証するCAFとLazy / Infのメモ化

上流RefCでは引数0個のトップレベル定義（CAF）が通常のC関数としてコンパイルされていたため、参照されるたびに再評価されていました。たとえば`counter = unsafePerformIO (newIORef 0)`を参照するたびに新しいIORefが生成されてしまう深刻な不具合がありました。rc2では専用の`RMemoize`ノードを導入し、アトミックに初回の計算結果をキャッシュ・共有することで、Chez Schemeと同様に正しい結果（`0 1 2`）を得られます。

同様に、上流RefCは遅延評価（`Delay` / `Force`）を通常のクロージャとして扱っていたため、同じ遅延値をforceするたびに再計算が発生していました。rc2は独自の`RDelay` / `RForce`ノードにより、最初の計算結果を安全にメモ化・共有します。

---

## %cg rc2ディレクティブによるチューニング

rc2はソースコード中の`%cg rc2 <directive>`ディレクティブや、CLIオプション`--directive VALUE`を通じて柔軟に動作をカスタマイズできます。

- **最適化パスの個別無効化（A/Bテスト・デバッグ用）**：`--directive noloop`（ループ最適化の無効化）や`--directive noconstfold`（定数畳み込みの無効化）のように、任意の段階を無効にして挙動や性能を比較できます。
- **IR・コードのダンプ**：`dumprcexpr`（人間に読みやすいRCExp IRの出力）、`dumpdualabi`、`dumpcc`。
- **外部Cコードの直接インライン展開**：`extraRuntime=<path>`（Cソースファイルの直接取り込み）や`inlineRuntime=<code>`（Cコードスニペットの埋め込み）。ビルドスクリプトでCFLAGSやLDFLAGSを設定することなく、独自のFFI実装を直接組み込めます。

詳細は[`rc2/doc/directives.md`](rc2/doc/directives.md)を参照してください。

---

## インクリメンタルコンパイル（--inc rc2）

RefCはインクリメンタルコンパイルに未対応ですが、rc2は上流の`Codegen.incCompileFile`基盤を実装しており、モジュール単位のインクリメンタルビルドをサポートしています。

```sh
idris2-rc2 --cg rc2 --inc rc2 -o program Program.idr
```

各モジュールは一度だけ対応するオブジェクトファイル（`.o`）にコンパイルされ、以降のビルドでは変更のないモジュールが再利用されます。標準パッケージ（`prelude`, `base`, `linear`, `contrib`, `network`）の合計272モジュールにおいて、インクリメンタルビルドの整合性を検証済みです。

なお、C構造体操作（`getField` / `setField` / `Struct`）はインライン展開を前提とするため、現時点では`--inc rc2`と併用できません（通常の一括ビルドでは問題なく動作します）。また、最大の効果を得るには標準ライブラリをあらかじめ`--inc rc2`でビルドしておく必要があります。詳細は[`rc2/doc/incremental-compile.md`](rc2/doc/incremental-compile.md)を参照してください。

---

## テストと品質保証

rc2では、テストスイートと各種サニタイザによって高い信頼性を維持しています。

### 一括回帰テスト（verify.sh）

```sh
cd rc2/tests
source ../../env.sh
nix-shell -p gcc gmp pkg-config valgrind --run './verify.sh'
```

`verify.sh`は以下のテストをまとめて実行します。

1. `idris2-rc2`およびランタイムのビルド
2. 上流RefCから移植した回帰テストスイートの実行（`rc2/tests/refc-suite/`）
3. 55個の手書きスモークテストの実行（期待される出力`.expected`との突合）
4. リーク検出対象テストに対する`valgrind --leak-check=full`によるメモリ検証
5. マルチスレッドテストに対するThreadSanitizer（TSan）によるデータ競合検証（`tsan.sh`）
6. スモークテストの全IRダンプに対する`tools/rcexpr-lint`静的検証

**主なオプションフラグ**
- `--skip-build`：コンパイラの再ビルドをスキップ
- `--no-valgrind`：valgrind検査を省略して高速実行
- `--valgrind-all`：全テストをvalgrind下で実行
- `--no-refc-suite` / `--no-tsan`：特定スイートを省略
- `--directive VALUE`：最適化無効化などのディレクティブを渡してテスト（例：`--directive noloop`）
- `--regen-expected`：スモークテスト変更時に期待値を再生成
- 環境変数`TEST_TIMEOUT`（秒、既定値60）：テスト実行タイムアウト値（valgrind / TSan実行時は10倍）

### 出力を変えない変更の検証（snapshot.sh, nopass.sh）

リファクタリングやコンパイラ高速化の際、生成されるCコードやIRに意図しない差分が生じていないかを確認できます。

- `snapshot.sh save DIR` / `snapshot.sh diff DIR` では、2回のテスト実行で生成されたIRとCコードをバイト単位で比較します。
- `nopass.sh` では、各最適化パスを1つずつ無効化しながらスモークテストを実行し、パス間の隠れた暗黙の依存関係を検出します。

### 性能測定ベンチマーク（bench.sh）

```sh
cd rc2/tests
nix-shell -p gcc gmp pkg-config --run './bench.sh'
```

`rc2/tests/Bench*.idr`を対象に、`idris2-rc2`と上流`idris2 --cg refc`の双方でコンパイル・実行し、実時間での速度向上比を計測・比較します（`--runs N`で試行回数指定、`--missing-containers`で外部データ構造ベンチマークを追加）。計測データと分析結果は[`rc2/BENCHMARKS.md`](rc2/BENCHMARKS.md)に記録されています。

### IRリンター単体テスト

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

---

## 現状とサポート範囲

rc2は、実用的な外部Cコード生成バックエンドとして機能しています。

### 検証済み機能

rc2では、以下の幅広い機能群の動作と安全性を検証済みです。

- **メモリ・値表現の最適化**：コンストラクタのその場再利用（In-place Reuse）、native型推論および二重呼び出し規約（Dual ABI）、C構造体による値返し（Struct Return）、連続dupの統合（DupMerge）、即値整数（Immediate Ints）、マルチスレッド対応のハイブリッド参照カウント
- **制御フロー・関数最適化**：自己末尾再帰・相互末尾再帰のループ化とループ不変式の巻き上げ、Tail Recursion Modulo Constructor（TRMC）、分岐局所へのlet沈め込み、プログラム全体のインライン化・定数畳み込み・デッドコード除去、クロージャおよび定数辞書の特殊化、world引数のarity raising
- **意味論の修正とビルド機能**：CAFおよびLazy / Infのアトミックメモ化、インクリメンタルコンパイル（`--inc rc2`）
- **標準ライブラリの拡張**：`Data.Buffer`、`System.Clock`、標準`network`パッケージのネイティブサポート

### 今後の課題とトレードオフの記録
末尾委譲呼び出しのネイティブ化や小型オブジェクト専用アロケータなど、現在検討・検証中の事項やあえて見送った技術的トレードオフの詳細は、[`TODO.md`](TODO.md)に網羅されています。各最適化パスの理論的背景やバグ修正記録については、[`rc2/doc/`](rc2/doc/)内の各設計ノートを参照してください。
