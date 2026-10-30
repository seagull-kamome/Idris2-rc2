# web

*[English](README.md)*

rc2向けのHTTPです。libcurlのクライアント、OpenAI互換のチャットクライアントとOAuth 2.0（PKCE）ログイン、2種類のHTTP/1.1サーバとルータ（`epoll`のイベントループ版と、`Control.Task`のタスクで作った版）が入っています。タスク版のサーバには、静的ファイル、CGI、リバースプロキシ、URLの書き換えも付きます。`rc2base`から切り出したパッケージで、土台になる汎用の部品（`Network.Async`、`Network.RC2`、`Network.URL`、`Control.Task`、`System.Linux.Epoll`など）は`rc2base`に残っています。`rc2base`と同じくrc2専用です（`%foreign`のバインディングがCだけのためです）。

使うプログラムは`-p web -p rc2base -p contrib`を付けてビルドします。`web`も`rc2base`も`network`パッケージは要りません（アドレスはrc2baseの`Network.Address.SocketAddress`（`network`パッケージと同じ名前）、ソケットは`System.Posix.Socket`のファイル記述子です）。クライアントには、libcurlの開発用ファイルとライブラリがコンパイラの検索パスに必要です。`web`にはCのシムが1つだけあります。`support/c/idris2rc2_web_curl_util.c`が`curl_global_init`をプロセスにつき1回呼び、`libidris2rc2web.a`にまとめられます。`rc2base`と同じように、パッケージの`lib`ディレクトリへインストールされます（`libs/rc2base/README.ja.md`の「ネイティブライブラリのインストール先」を参照）。

## モジュール

| モジュール | 内容 |
| --- | --- |
| `Network.HTTP.Message` | `Request`、`Response`、リクエストのパーサ。HTTPサーバ間で共有します |
| `Network.HTTP.Server` | 最小限のシングルスレッド・`epoll`駆動のHTTP/1.1サーバ。後述 |
| `Network.HTTP.Route`/`Router` | `Network.HTTP.Server`の上に作った、型安全なルートテーブル。後述 |
| `Network.Async.HTTP.Server`/`Router` | Taskで作ったHTTP/1.1サーバおよびルートテーブル（ハンドラは`Task Response`を返します）。`doc/async-http-server.md`を参照。`Network.Async.HTTP.Static`/`CGI`/`Proxy`/`Rewrite`は、静的ファイル、外部CGIプログラム、リバースプロキシ（`Handler`の変換、または`routerWith`のルートとして）、URLの書き換えをこのルータに加えます。`doc/async-http-router.md`を参照。`Network.Async.HTTP.Stream`はチャンク転送やイベントストリームのボディを読みます。`doc/async-http-stream.md`を参照 |
| `Network.HTTP.Client` | `fetch()`の形をしたクライアントインターフェース`HTTPClient`。`doc/http-client.md`を参照 |
| `Network.Async.HTTP.Client` | `Task`として使うクライアント`AsyncHTTPClient`。`Network.Async.HTTP.Client.Curl`がlibcurl版（`fetchAsync`、`streamAsync`）。`doc/async-http-client.md`を参照 |
| `Network.HTTP.Client.Curl.*` | libcurlのクライアント（`Curl`: `curlClient`）、バインディング（`Raw`、`Types`）、`TextBuffer`への取り込み。`doc/http-client.md`を参照 |
| `Network.HTTP.Client.WebAPI.*` | OpenAI互換のチャットクライアント、OAuth 2.0（PKCE）ログイン。`doc/http-client.md`と`doc/webapi-getting-started.md`を参照 |

`examples/`に小さなプログラムがあり（`doc/http-client.md`を参照）、`bench/`には2つのサーバを`wrk`で比べるスクリプト（`bench/bench.sh`）があります。

## テスト

配置は`libs/rc2base/tests`と同じです。`tests/<TestName>/`に`<TestName>.idr`と`<TestName>.expected`を置き、`tests/verify.sh`の`TESTS`配列に載せます。スクリプトは`support/c`を作り直し、パッケージを型検査してインストールしたうえで、すべてのテストを`-p web -p rc2base [-p <追加>...]`でビルドして実行します。先に`rc2base`をインストールしておく必要があります（`libs/rc2base/tests/verify.sh`が行います）。`TestCurl`、`TestWebAPI`、`TestAsyncHTTPClient`はlibcurlのヘッダが必要で、`gcc`が`curl/curl.h`を見つけられないときは`SKIP`の行を出して飛ばします。`TestAsyncHTTPStaticCGI`は`public/`と`cgi/`の場所を実行ファイルのパスから割り出すので、フルパスで起動してください。

## `Network.HTTP.Server`: 最小限のイベント駆動HTTPサーバ

シングルスレッドの`epoll`駆動HTTP/1.1サーバです。生のイベントループが`System.Linux.Epoll`、バイナリ安全なバッファのソケットIOが`Network.RC2`、その上のHTTPの論理が`Network.HTTP.Server`です。

1回の呼び出しで起動します。各リクエストには、戻り値でなく継続で応答します。そのため`Handler`は、同期的に応答することも、継続を取っておいて後で（別スレッドからでも）応答することも、ループを`stop`することもできます。リクエストとレスポンスのボディは、生の`Data.Buffer`のバイト列で、バイナリ安全です。

`Response.*`のコンストラクタ（`text`/`html`/`json`/`ok`/`notFound`/`bytes`/...）でレスポンスを作ります。そのまま呼ぶか、名前が衝突するときは`Response.`で修飾します。いずれも、先頭に省略可能な暗黙の`headers`を取ります。

```idris2
import Language.JSON
import Network.HTTP.Server

handler : Handler
handler req respond =
  case req.path of
    "/hello" => respond !(text 200 "hello\n")
    "/echo"  => respond (MkResponse 200 [] req.body)          -- 生のバイト列
    "/img"   => respond (bytes 200 "image/png" pngBuf)
    "/api"   => respond !(json 200 (JObject [("ok", JBoolean True)]))
    _        => respond !(notFound "not found\n")

main : IO ()
main = serve 8080 handler   -- 127.0.0.1:8080にbindし、`stop`されるまで動きます
```

Linux専用（`epoll`）です。リクエスト行、ヘッダ、`Content-Length`のボディ、チャンク転送のリクエストボディ（復号します）、keep-aliveに対応し、チャンク転送の応答、HTTP/1.0、TLS、パイプライン処理のレスポンス順序には対応しません。読み取りアキュムレータには上限があります（`serve`の`maxRequestBytes`、既定は8 MiB）。大きすぎるリクエストは、応答なしで捨てられます。

完全な設計は`doc/http-server.md`を参照してください。そこには、このモジュール自身のテストプログラムがぶつかった、正しさの落とし穴も書いてあります。トップレベルで`unsafePerformIO`した`IORef`が、`--cg chez`ではメモ化されるのに、`--cg rc2`（上流の`--cg refc`も同様）ではメモ化**されない**ことです。参照のたびに、共有でなく新しい`IORef`が黙って作られます。このパターンで`Handler`をまたいで状態を共有してはいけません。代わりに、`main`で`IORef`を作って渡してください。

## `Network.HTTP.Route`/`Router`: 型安全なルートテーブル

キャプチャが生む型で添字づけたパスのパターンと、その上のExpress風のルートテーブルです。`router`は`List RouteEntry`から素の`Handler`を直接作るので、ほかに何も変えずに`serve`へ差し込めます。

```idris2
import Network.HTTP.Route
import Network.HTTP.Router
import Network.HTTP.Server

usersShow : Route [Int]
usersShow = "users" // capture "id" Int end

routes : List RouteEntry
routes = [ get usersShow (\userId, respond => respond (MkResponse 200 [] "user #\{show userId}\n")) ]

main : IO ()
main = serve 8080 (router notFoundHandler routes)
```

キャプチャが`n`個あるルートには、型`ty1 -> ... -> tyn -> (Response -> IO ()) -> IO ()`のハンドラが必要で、これはコンパイル時に検査されます。`FromSegment`の解析失敗（またはリテラルのセグメントやメソッドの不一致）は、クラッシュせず、次に登録されたルートへ素通りします。

完全な設計は`doc/http-router.md`を参照してください。そこには、次の2点の理由も書いてあります。

- `capture`が、固定セグメントのように`//`で連ねるのでなく、関数呼び出しとして入れ子になる理由
- パスの分割が、文字列を1回走査するだけ（`strSubstr`による再走査がない）である理由

