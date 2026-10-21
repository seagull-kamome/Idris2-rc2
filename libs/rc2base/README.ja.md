# rc2base

*[English](README.md)*

```
libs/rc2base/
├── rc2base.ipkg   Idris2パッケージ: Control.Concurrent.{MVar,Atomic}, Control.Task.*,
│                  Data.Text/Data.TextBuffer, Data.String.{FFI,RC2},
│                  Data.Double.{RC2,Convert}, Data.IORef.RC2, Data.Integer.GMP, Data.Queue,
│                  Language.RCExpr.{AST,Lexer,Parser},
│                  Network.{RC2,URL}, Network.HTTP.{Route,Router,Server,Client.*},
│                  System.Concurrency.RC2, System.FFI.C.*, System.GC.RC2,
│                  System.Linux.*（Epoll, Uring ほか）, System.Posix.*,
│                  System.Random.Xoroshiro{128PlusPlus,64StarStar},
│                  Text.Encoding.UTF8, Text.Regex.POSIX
├── src/           上記モジュールのIdris2ソース
├── support/c/     Cシム（libidris2rc2base.a）。prebuild / postinstallフックでビルド
├── doc/           主要コンポーネントの設計ノート（http-router.md、http-server.md、regex-posix.md、url.md、task.md、uring.md ほか）
└── tests/         各モジュールの単体テスト（verify.sh）
```

上流の`base`や`contrib`に欠けている、または不十分な機能を補う基盤パッケージです。

- **高速Web・ネットワーク**：`System.Linux.Epoll`を基盤とするイベント駆動型HTTP/1.1サーバ（`Network.HTTP.Server`）、型安全なExpress風ルータ（`Network.HTTP.Route` / `Router`）、URLパーサ（`Network.URL`）。
- **並行処理・同期プリミティブ**：Haskell風の`MVar`、アトミックカウンタ（`Control.Concurrent.*`）、OSネイティブのスレッドとMutex（`System.Concurrency.RC2`）。
- **非同期I/O**：`Control.Task`（イベントソース上の協調的な`Task`モナド）、liburing経由の`io_uring`（`System.Linux.Uring`、設計は[`doc/uring.md`](doc/uring.md)）。liburingのヘッダとライブラリが必要なのは、このモジュールをimportするプログラムだけです。
- **低レベルC連携とメモリ**：POSIX正規表現（`Text.Regex.POSIX`）、GMP整数演算（`Data.Integer.GMP`）、メモリバッファ、生UTF-8バイト列の変換（`Text.Encoding.UTF8`）、不透明なFFI値に対する参照カウントの明示的な操作（`System.GC.RC2`）。
- **コンパイラ解析基盤**：rc2が出力するIRダンプのパーサ（`Language.RCExpr.*`）。

モジュールごとの設計ノートとビルド・テストの手順は、英語版の[`README.md`](README.md)を参照してください。
