# control-async

*[English](README.md)*

rc2向けの協調型タスクです。spawn/both/raceとキャンセルを備えた`Task`モナド、`epoll`（とタイマー、liburingがあれば`io_uring`）の上のスケジューラ、複数スレッドで状態を共有するための`Ref`/`MVar`/`Chan`、そしてそのためのノンブロッキングソケット（`Network.Async`）が入っています。`rc2base`から切り出したパッケージで、土台になるシステムコールの層（`System.Linux.*`、`System.Posix.*`、`Network.Address`、`Network.RC2`、`Data.Queue`、`System.Concurrency.RC2`）は`rc2base`に残っています。タスクの上で動くHTTPのサーバとクライアントは`web`にあります。`rc2base`と同じくrc2専用です。

使うプログラムは`-p control-async -p rc2base -p contrib`を付けてビルドします。Cのコードは持たず、`Control.Task.Uring`を使わなければliburingも要りません。

## モジュール

| モジュール | 内容 |
| --- | --- |
| `Control.Task` | `Task`モナド。spawn/both/race、キャンセル、タイマー、`handoff`、`finally`。`doc/task.md`を参照 |
| `Control.Task.Scheduler` | タスクを動かすスケジューラ（`runTaskWith`、`Env`、`turn`） |
| `Control.Task.Source`、`Control.Task.Epoll` | 差し替え可能なイベントソースと、`epoll`のもの |
| `Control.Task.Uring` | rc2baseの`System.Linux.Uring`の上の、`io_uring`のイベントソース（使うときだけliburingが必要です） |
| `Control.Task.Pool`、`Control.Task.Waiters` | 並列モードでアクションを動かすワーカースレッドと、次のプリミティブが共有する待ちリスト |
| `Control.Task.Ref`、`MVar`、`Chan` | 複数スレッドのタスクの間で共有する状態 |
| `Network.Async` | スレッドをブロックせず、スケジューラ上でディスクリプタを待つ`accept`、`connect`、`recv`、`send` |

## テスト

配置は`libs/rc2base/tests`と同じです。`tests/<TestName>/`に`<TestName>.idr`と`<TestName>.expected`を置き、`tests/verify.sh`の`TESTS`配列に載せます。スクリプトはパッケージを型検査してインストールしたうえで、すべてのテストを`-p control-async -p rc2base [-p <追加>...]`でビルドして実行します。先に`rc2base`をインストールしておく必要があります（`libs/rc2base/tests/verify.sh`が行います）。`TestTaskUring`は`gcc`が`liburing.h`を見つけられないときは`SKIP`の行を出して飛ばします。`TestTaskNoUring`は、`Control.Task.Uring`をimportしても使わないプログラムが、liburingなしでビルドできることを確かめます。`TestNetworkAsync`は、クライアントに`network`パッケージを使います。
