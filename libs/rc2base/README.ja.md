# rc2base

*[English](README.md)*

rc2の汎用サポートライブラリです。上流の`base`/`contrib`に無い、あるいは
rc2が必要とするネイティブC ABI向けには不十分な機能を提供します。最初は
UTF-8由来のコードポイントバッファを包む`Data.Text`型だけでしたが、その後、
小さなイベント駆動型HTTP/1.1サーバとルータ、URL解析、POSIX正規表現の
バインディング、GMP `Integer`のバインディング、ゼロから書いた2つの乱数生成器、
ポインタ・配列・バッファ向けの生のFFIヘルパなどが加わりました。1つの式で書けないバインディングは
`support/c/`にある少数のCシム（後述の「FFI: CExprと残ったシム」を参照）が受け持ち、
すべてがパッケージの`prebuild`フックによって
`support/c/libidris2rc2base.a`という1つのライブラリにまとめてリンクされます。
`idris2 --install`はこの`.a`とそのヘッダを自力では扱えません。インストール済みの
パッケージのどこにどう置かれるかは、後述の「ネイティブライブラリのインストール先」を
参照してください。

## FFI: CExprと残ったシム

本体がlibcやGMPの呼び出し1つ、定数、マクロ、または小さな純粋式で済むバインディングは、
`"CExpr:"`の`%foreign`テンプレート（`rc2/doc/ffi-cexpr.md`）で書き、Cシムを持ちません。
該当するのは、`Data.Integer.GMP`のすべての`mpz_*`バインディング（`$r`が`Integer`の
出力引数）、`System.FFI.C.Ptr`のfetch/storeの組（`((ty *)p)[i]`）、`System.Posix.*`の
各モジュール（`Directory.readdir`は、不透明な`DirEnt`をPrimIOのCExprアクセサ経由で読み、
`DirEntry`へコピーします。`struct dirent`はtypedef名ではないので`Struct`では名指せません）、
`Network.RC2`の`send`/`recv`、`EPOLL*`定数、`System.Linux.Epoll`（`struct epoll_event`を
アクセサ経由で読む）、`System.Linux.Eventfd`、`Text.Regex.POSIX`の`REG_*`定数と`re_nsub`、
`Data.TextBuffer`のアクセサと`free`、`Data.String.RC2`のバイト長・バイト列からの構築ヘルパ、
`Control.Concurrent.Atomic`、`System.GC.RC2.touch`です。ヘッダの欄には実際のシステムヘッダを
書きます。

シムが残るのは、式1つでは書けないときです。制御フローやループ（epollのコードには
もう残っていません）、静的変数やスレッドローカル状態（正規表現のマッチキャッシュと
エラーバッファ、`xoroshiro`のシステムシード）、確保と後始末（`regex_compile`/`regex_free`、
`TextBuffer`のビルダ、クランプ処理を持つ`string_byte_slice`、`double_convert`）、
そしてランタイムのクロージャ・値API（`concurrency_util`）です。

`_GNU_SOURCE`が必要な宣言（`O_DIRECT`、`O_LARGEFILE`、`O_NOATIME`、`O_PATH`、
`O_TMPFILE`、`AT_EMPTY_PATH`、`SEEK_DATA`、`SEEK_HOLE`、`dup3`、`preadv2`/`pwritev2`、
`memfd_create`と`MFD_*`・`F_SEAL_*`の各シール、`splice`と`SPLICE_F_*`、
`copy_file_range`、`statx`、`System.Linux.Process`のCPUセットマクロ）は、
生成コードが自分では`_GNU_SOURCE`を定義しないため、Idrisコンパイラの環境に
`IDRIS2_CFLAGS=-D_GNU_SOURCE`（または`CFLAGS=-D_GNU_SOURCE`）を設定してプログラムを
ビルドしてください。該当する宣言には、いずれもdocコメントでその旨を書いてあります。
フラグが無いと、その宣言を使った時点で生成されたCがコンパイルできません。

## モジュール

| モジュール | 用途 |
| --- | --- |
| `Control.Concurrent.MVar` | Haskellの`MVar`（スレッド安全な`takeMVar`/`putMVar`/`modifyMVar`/...）。`System.Concurrency`の`Mutex`/`Condition`の上に作ってあります |
| `Data.Text`/`Data.TextBuffer` | UTF-8由来のコードポイントバッファ。後述の「API」を参照 |
| `Data.String.FFI` | 上流`Data.String`の`%foreign`の欠落を補います。`TODO.md`を参照 |
| `Data.String.RC2` | `String`をバイトオフセットで切り出します。範囲がコードポイントの境界に揃わないときに使います。後述 |
| `Data.Double.RC2` | 上流`Data.Double`の`unitRoundoff`/`epsilon`/`nan`/`inf`を補います。後述 |
| `Data.Double.Convert` | `Double`と`String`の相互変換を速くする、Eisel-Lemire/Grisu2系の任意利用の経路。`cast`を置き換えず、その隣に置いてあります。後述 |
| `Data.Integer.GMP` | 本物のGMP `mpz_*`関数への直接の`%foreign`バインディング。後述 |
| `Language.RCExpr.AST`/`Lexer`/`Parser` | rc2自身の`--directive dumprcexpr`の出力を、独立した木に解析します。後述 |
| `Network.RC2` | `Data.Buffer`に対する、バイナリ安全でオフセットと長さを指定できるソケットIO |
| `Network.URL` | URLの解析・構築とパーセントエンコード。後述 |
| `Network.HTTP.Route`/`Router` | `Network.HTTP.Server`の上に作った、型安全なルートテーブル。後述 |
| `Network.HTTP.Client` | `fetch()`の形をしたクライアントインターフェース`HTTPClient`。`doc/http-client.md`を参照 |
| `Network.HTTP.Client.Curl.*` | libcurlのクライアント（`Curl`: `curlClient`）、バインディング（`Raw`、`Types`）、`TextBuffer`への取り込み。`doc/http-client.md`を参照 |
| `Network.HTTP.Client.WebAPI.*` | OpenAI互換のチャットクライアント、OAuth 2.0（PKCE）ログイン。`doc/http-client.md`を参照 |
| `Network.HTTP.Server` | 最小限のシングルスレッド・`epoll`駆動のHTTP/1.1サーバ。後述 |
| `System.Posix.*` | POSIXバインディング。`Errno`、`File`/`FileDesc`（`FileDesc`/`DirDesc`は`Int32`と、それが負でないという消去された証明を持ちます）、`Directory`、`Dl`（`dlopen`/`dlsym`/`dlclose`）、`Path`（`mkdir`、`unlink`、`symlink`、`readlink`、`realpath`、`mkfifo`、`mkstemp`など）、`Stat`（`stat`/`lstat`/`fstat`を`Stat`レコードへ、`access`、`truncate`、`utimensat`）、`Time`（`clock_gettime`、`nanosleep`、`gmtime`/`localtime`/`mktime`/`strftime`）、`Fcntl`（`pipe`、`fcntl`のフラグ、`dupfd`）、`Poll`（`poll`）、`Select`（`select`）、`Pwd`（`getpwnam`/`getpwuid`/`getgrnam`/`getgrgid`を`Passwd`/`Group`レコードへ）、`Glob`（`fnmatch`、`glob`）、`Syslog`（`openlog`/`syslog`/`closelog`）、`Mmap`、`Process`（各種ID、プロセスグループ、`exec*`、wait状態の判定、`getrlimit`、`uname`、`sysconf`、`sigqueue`）、`Signal`（番号、シグナル集合、`sigprocmask`、`sigwait`、`sigtimedwait`、`sigsuspend`、`raise`、`alarm`）、`Uio`、CのstdioをまとめたStdio（`File = Ptr RawFile`、errnoは`Left`に入ります。`open_memstream`は`MemStream`）。POSIXの範囲を外れる宣言には、docコメントに「Linux only」「Linux and BSD」などと書いてあります |
| `Control.Task`、`Control.Task.Scheduler`/`Epoll`/`Source` | 差し替え可能なイベントソースの上に作った、協調型の`Task`モナド（今は`epoll`とタイマー、`io_uring`は`System.Linux.Uring`が束縛を担います）。spawn/both/raceとキャンセルを備えます。`doc/task.md`を参照 |
| `System.Concurrency.RC2` | 本物のpthreadを使った`Mutex`/`Condition`/`Semaphore`/`Barrier`/`Channel`と、joinできる`forkJoin`。設計の全体は、トップレベル`README.md`の「Concurrency」の節を参照 |
| `System.FFI.C.Array` | `malloc`で確保され、GCが解放し、`Fin`で境界検査される固定長配列 |
| `System.FFI.C.Ptr` | `Ptr`/`GCPtr`の領域に対する、検査なしの要素番号指定のfetch/store |
| `System.FFI.C.Sizeof` | スカラー型のCの`sizeof`。バッファの刻み幅やオフセットを手で計算するときに使います |
| `System.GC.RC2` | rc2自身の`idris2rc2_dup`/`dup_n`/`drop`への直接アクセス。不透明なFFIポインタ経由で持ち出した値に使います |
| `System.GC.RC2.touch` | `touch x`は、そのアクションまで`x`を生かしておきます（GHCの`touchForeignPtr`）。`unsafeGCDup`/`unsafeGCDrop`と違い、どの値に対しても安全です |
| `System.Linux.*` | Linux専用のバインディング。`Epoll`（`Network.HTTP.Server`のイベントループを支える薄い`epoll`のFFIラッパ）、`Pipe`（`pipe2`）、`Eventfd`、`Memfd`（`memfd_create`とファイルシール）、`Copy`（`sendfile`、`splice`、`copy_file_range`）、`Prctl`、`Statx`（生成時刻とマウントID付きの`statx`）、`Random`（`getrandom`）、`Process`（`gettid`、`pidfd_open`、CPUアフィニティ）、`Timerfd`、`Signalfd`、`Inotify`、`Uring`（liburing経由の`io_uring`、`doc/uring.md`。importするプログラムにはliburingのヘッダとライブラリが必要です）、`Clock`（`CLOCK_BOOTTIME`など）、`Dl`（`dladdr`、追加の`dlopen`フラグ） |
| `System.Random.Xoroshiro128PlusPlus`/`Xoroshiro64StarStar` | ゼロから移植した2つの乱数生成器。後述 |
| `Text.Encoding.UTF8` | UTF-8のバイト列とコードポイントの相互変換。純粋な`List`変換です。後述 |
| `Text.NumberFormat` | すべての固定幅整数型に対する、固定幅・ゼロ詰め・小文字の16進表記（`ToHex`）。後述 |
| `Text.Regex.POSIX` | libcの`<regex.h>`へのバインディング。後述 |

（`Text.Regex.RE2`もかつてはここにありました。移動先とその理由は、末尾の
「RE2による正規表現: `text-re2`」を参照してください。）

## ビルドとテスト

既定のChezバックエンドで、型検査だけを行う場合:
```sh
idris2 --build rc2base.ipkg
```

`rc2base.ipkg`自体の型検査にとどまらず、`tests/TestText/TestText.idr`をこのライブラリに
対してビルドするには、先にライブラリをローカルのprefixへインストールします。ここでは
Idris2の既定のパッケージ置き場が読み取り専用のnixストアにあるためで、理由は
`idris2-curl/AGENT.md`の「Build & test」の節と同じです:
```sh
export IDRIS2_PREFIX="$(pwd)/.local-install"
idris2 --install rc2base.ipkg
```

`idris2-rc-cg`自身の`rc2`バックエンドに対してビルドする場合です（`libs/rc2base`は
`idris2-rc-cg`の中にあるので、`idris2-curl`のような外部の利用者と違い、別のリポジトリを
チェックアウトしたり`env.sh`をまたいで読み込んだりする必要はありません）。rc2自身が使う
*同じ*`install/`のprefixへインストールします。idris2は自分のインストールprefixを既定で
探すので、パッケージパスの別設定は要りません。上の一般的な手順と違い、`IDRIS2_PREFIX`の
export も要りません。`env.sh`のセルフビルドの`idris2`は、このリポジトリの`install/`を
最初から既定にしています（`idris2 --prefix`で確認できます）:
```sh
cd idris2-rc-cg   # リポジトリのルート
source ./env.sh
(cd libs/rc2base && idris2 --install rc2base.ipkg)

./rc2/build/exec/idris2-rc2 --cg rc2 -p rc2base -o TestText libs/rc2base/tests/TestText/TestText.idr
./build/exec/TestText
```
ここでは`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`/`LD_LIBRARY_PATH`のexportは一切要らず、
`-p rc2base`だけで足ります。`Compiler.RC2.CC`の`depPkgLibDirs`が、`-p`で指定された
すべてのパッケージのインストール済み`lib/`を辿り、`-I<...>/lib`（これで`text_util.h`と、
それや他の`support/c/`のヘッダがベア名で`include`する`datatypes.h`/`memory.h`/`utf8.h`が
自動的に見つかります）と`-L<...>/lib`（これで`libidris2rc2base.a`が、手動の
`IDRIS2_LDFLAGS`なしでリンクされます）の両方を加えます。後述の「ネイティブライブラリの
インストール先」を参照してください。コンパイル済みのrc2プログラムが起動時に必要とする
共有ランタイムの`.so`は`libidris2_support.so`の1つだけで、ツールチェーン自身の
`install/idris2-0.8.0/lib`にあり、`env.sh`がすでに`LD_LIBRARY_PATH`へ入れています。
`support/rc2`自体には、そこへ加えるべき`.so`はありません。

## テストの配置

テストはそれぞれ専用のディレクトリ`tests/<TestName>/`に置き、`<TestName>.idr`
（`module Main`が1つ）と`<TestName>.expected`（コンパイルしたプログラムが出力すべき
標準出力そのもの）を入れます。`tests/verify.sh`が唯一のドライバで、パッケージを
再ビルドしてインストールしたあと、各テストのディレクトリの中から
`idris2-rc2 --cg rc2 -p rc2base [-p <追加>...]`でビルドし（出力はgit管理外の
`tests/<TestName>/build/`）、`LC_ALL=C.UTF-8`のもと`ulimit -v 4000000; timeout 20`で
実行して、出力を`<TestName>.expected`と比較します。テストは`verify.sh`の`TESTS`配列
（名前、追加の`-p`パッケージ、説明）に明示的に並べます。`tests/*/`のディレクトリが
一覧に無い、または一覧のテストにディレクトリ・`.idr`・`.expected`が無いと、スクリプトは
失敗します。テストを足すには、その2つのファイルを入れたディレクトリを作り、`TESTS`に
1行加えます。`TestCurl`はlibcurlのヘッダが必要で、`gcc`が`curl/curl.h`を見つけられない
ときは`SKIP`の行を出して飛ばします。`TestUring*`も同様に、`liburing.h`が無ければ飛ばします。

## ネイティブライブラリのインストール先

Idris2のパッケージの規約（`idris2-src/docs/source/reference/packages.rst`の
「Support file install directories」）では、パッケージのインストールルート直下の
2つのサブディレクトリ、`lib`（コンパイル済みライブラリ）と`data`が特別扱いされます。
`idris2 --install`はインストールルート自体を作り、`.ttc`/`.ttm`/`.ipkg`をそこへ
コピーしますが、このパッケージがCシムも配布することは知らないので、`lib`を作ることも
中身を置くこともしません。それを行うのがこのパッケージの`postinstall`フック
（`rc2base.ipkg`、`support/c/postinstall.sh`を実行）です。`idris2 --install`のあと、
`libidris2text.a`と`text_util.h`が
`<IDRIS2_PREFIX>/idris2-<idris2のバージョン>/rc2base-0.1.0/lib/`に置かれます。

この`lib`の規約は、ChezやRacketのバックエンドも自分の目的で自動的に利用します
（ビルド時に依存パッケージの`lib/`から`.so`/`.dylib`を`dlopen`するもので、設定は
要りません。`Compiler.Common`の`locate`/`copyLib`が、`Core.Directory.findLibraryFile`
経由で行います）。しかしrc2は、上流のRefCと同じく`%foreign`のライブラリを静的に
リンクします。上流の`lib_dirs`（`idris2-src/src/Idris/Driver.idr`）は、依存パッケージ自身の
`lib/`を`-L`の検索パスに自動で加えることが一切ありません（加わるのは`IDRIS2_LIBS`、
ツールチェーン自身のインストール先、カレントディレクトリだけです）。rc2は同じ目的の
ために別の仕組みを持っています。`Compiler.RC2.CC`の`depPkgLibDirs`（`ef045b0`で追加）が、
現在ロードされている（`-p`された）すべてのパッケージのインストール先を辿り、rc2の
コンパイルのたびに`-I<...>/lib`と`-L<...>/lib`の両方を自動で加えます。したがって
`-p rc2base`でビルドする利用者は、このパッケージの`lib/`を指すように
`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`を手で設定する必要がありません（上の「ビルドとテスト」を
参照）。`lib/`へのインストールは、これらすべてが乗る土台として依然として必要です
（ソースのチェックアウトに散らばらない、持ち運べて完結したインストール済みコピーに
なります）。上流のRefCと違い、rc2では`depPkgLibDirs`のおかげでその土台だけで十分に
なっています。

## 注意: `%foreign`のlib欄はパスではなく、ベアな`-l`名にする

rc2は、`%foreign`宣言ごとのlib欄から`-l<name>`のリンカフラグを自動で導きます
（`Compiler.RC2.Emit`の`linkLibName`）。ただしそれは、欄の値が文字どおり
`"lib"`で始まるときだけで、その接頭辞を取り除いた残りをそのまま`-l`に渡します。
これはファイルパスでは*ありません*。`"libs/rc2base/support/c/libidris2text.a"`のような
欄は、`linkLibName`が想定する意味では`"lib"`で始まりません（偶然、接頭辞の検査に
合致してしまうと、スラッシュ入りの壊れた`-l`フラグができます）。どちらの場合も
`-l<lib>`はリンカに届かないまま黙って落ち、そのライブラリのシンボルがすべて
`undefined reference`になります。その間、rc2のコンパイル手順は最後のリンクまで
成功したと報告します。

正しい形（`src/Data/Text.idr`が使っているもの）は、`"lib"`で始まり、パスも拡張子も
付かないベアなライブラリ名です:
```idris2
%foreign "C:idris2rc2_String_to_TextBuffer,libidris2text,text_util.h"
prim__String_to_TextBuffer : String -> PrimIO AnyPtr
```
これは`-lidris2text`になります。リンカには、`libidris2text.a`がどこにあるかも伝える
必要があります（既定の検索パスには無いため）。`-p rc2base`のビルドでは、
`depPkgLibDirs`（上の「ネイティブライブラリのインストール先」を参照）が自動で
処理するので、`IDRIS2_LDFLAGS`を手で設定する必要はありません。素の上流のChez、および
`idris2 --cg refc`のビルドは`-l`フラグを自動で導きもしないので、rc2固有のこうした
仕組みはもともと不要です（ChezのFFIは、`%foreign`のlib欄を実行時に名前で動的ロード
します）。

## API

```idris2
data Text : Nat -> Type
```
Unicodeのコードポイント列です。長さ`n`（バイト長ではなくコードポイント数）が
型に入っています。

```idris2
fromString : (s : String) -> (n : Nat ** Text n)
toString   : Text n -> String
length     : Text n -> Nat
index      : {n : Nat} -> Text n -> Fin n -> Char
(++)       : Text n -> Text m -> Text (n + m)
```
すべて純粋で、構築・変換・添字アクセス・連結に`IO`は要りません。解放は自動です。
すべての`Text`は`GCAnyPtr`を包み、そのネイティブバッファは、値が到達不能に
なるとGCのファイナライザ（`onCollectAny`）が解放するので、呼び出すべき明示的な
`free`はありません。

```idris2
0 lengthCorrect : {n:Nat} -> (xs:Text n) -> length xs = n
```
意図的に置いた、消去される（数量`0`でランタイムの費用がない）公理です。機械的に検査
された証明ではありません。`length`は毎回、不透明なCのFFI呼び出しを通して`n`を読み直す
ので、Idrisの証明検査器にはその中が見えません。代わりに構成によって成り立ちます。
すべての`Text`値はこのモジュール自身のスマートコンストラクタ経由でしか得られず、
そのいずれもCバッファの`len`フィールドをちょうど`n`に設定し、ここにはその後で
バッファの`len`を変更する操作が1つもありません。

`toString`の実装は特筆に値します。`text_util.c`の
`idris2rc2_TextBuffer_to_string`は、完全に組み立てられ、タグも正しい
`IDRIS2RC2_String`をC側で直接作り（rc2自身の`idris2rc2_mkEmptyString`経由）、
Boxedな`Value*`として返します。Idris側の`%foreign`宣言の戻り値の型は`String`ではなく、
局所的で値を作らない不透明なマーカー（`RawTextValue`）です。`String`と宣言すると、
rc2自身のFFIマーシャラが、すでにBoxedな値を`idris2rc2_mkString`で*もう一度*包んで
しまいます。認識されない戻り値の型はrc2の`CFUser`の場合に対応し、その詰め込みと
取り出しは恒等なので、値はそのまま通過します。そして`believe_me`が、実行時にはすでに
成り立っていることを型検査器に伝えます。これで、中間の`char *`バッファ経由の余計な
コピーを避けられます。

### `System.Random.Xoroshiro128PlusPlus` / `System.Random.Xoroshiro64StarStar`

本物のxoroshiro128++とxoroshiro64**のアルゴリズム（Blackman & Vigna、2019、パブリックドメイン）を
Cへ移植したものを、薄いFFIで包んだ2つのモジュールです。それぞれ、xoshiro/xoroshiro系列の
うち、出力64ビット・状態128ビットのものと、出力32ビット・状態64ビットのものにあたります。
名前は似ていますが、一方が他方を縮小した変種というわけではありません。参照元のC実装は
[xoroshiro128plusplus.c](https://prng.di.unimi.it/xoroshiro128plusplus.c)と
[xoroshiro64starstar.c](https://prng.di.unimi.it/xoroshiro64starstar.c)で、機械的に名前を
付け替えて`support/c/xoroshiro128plusplus.c`と`xoroshiro64starstar.c`にしてあります
（Cのシンボル接頭辞はそれぞれ`idris2rc2_System_Random128_*`と`idris2rc2_System_Random_*`
です。「128」の付かない接頭辞のほうが128ビット側ではなく64ビット状態のモジュールのものなので、
見た目と逆になっている点に注意してください）。作った理由は、上流contribの`System.Random`が
すべて`%foreign`頼みで、実装が`scheme:`と`javascript:`にしかなく、refcやrc2（どのCバックエンド
でも）では全く使えないからです（`TODO.md`の「Upstream stdlib `%foreign` declarations with no
C/RefC backend at all」を参照）。どちらのモジュールもそのプリミティブへのパッチではなく、
独自のAPIを持つ独立した置き換えです。純Idrisへの移植ではなくCのままにしたのは、主に、参照
アルゴリズム自身の`jump()`/`long_jump()`/`jump_ce()`/`jump_n()`の仕組みを、F2X多項式演算を
ゼロから移植することなく、後述のとおり使えるようにするためです。

2つのモジュールは同じ形のAPIを持ちます:

```idris2
export
data IOGen  -- 不透明。生の状態を持つBufferを包みます

newIOGen   : HasIO io => Bits64 -> io (Maybe IOGen)
copyIOGen  : HasIO io => IOGen -> io (Maybe IOGen)
next       : HasIO io => IOGen -> io Bits32   -- Xoroshiro128PlusPlusではBits64
nextDouble : HasIO io => IOGen -> io Double
newSeeded  : HasIO io => io (Maybe IOGen)

jump     : HasIO io => IOGen -> io ()
longJump : HasIO io => IOGen -> io ()
jumpCE   : HasIO io => IOGen -> (c : Bits64) -> (e : Bits32) -> io ()
jumpN    : HasIO io => IOGen -> (n : Bits64) -> io ()   -- Xoroshiro128PlusPlusではBits64を2語
```
これに加えて、単一のグローバル生成器（後述）を操作する`setSystemSeed`/`nextIO`/`jumpIO`/
`longJumpIO`/`jumpCEIO`/`jumpNIO`の一群があります。

`IOGen`はアルゴリズムの生の状態（Xoroshiro64StarStarは8バイト、Xoroshiro128PlusPlusは16バイト）
を持つ`Buffer`を包み、`next`や`jump`系がそれをその場で書き換えます。純粋な値として手で
引き回したり、`IORef`の裏に隠したりはしていません。`next`は`"C"`タグ経由で参照のCアルゴリズムを
直接呼び出します。`Compiler.RC2.EmitUtil`の`extractValue CLangC CFBuffer`が`Buffer`引数を
そのデータを直接指す平らなポインタに展開する（途中にサイズヘッダはありません）ので、C側は
それを参照アルゴリズム自身の`uint32_t s[2]`/`uint64_t s[2]`とまったく同じに扱え、連続する語を
ネイティブエンディアンで読みます。これがバッファ自身の（`Data.Buffer.setBits32`/`setBits64`が
構成上そうなる）リトルエンディアンの配置と一致するのは、現実的なリトルエンディアンの環境
（x86/x86_64/ARMの既定モード）だけです。このプロジェクトが他でも頼っている前提であり、実際には
危険ではありません。`newIOGen`/`copyIOGen`/`newSeeded`は`Maybe`を返し、`Nothing`になるのは
バッファの確保に失敗したときだけです。素の`newIORef`には無かった、`Buffer`を使う設計に特有の
可能性です。`copyIOGen`は生成器の現在の状態を、2つ目の独立した`IOGen`（新しい`Buffer`を
`Data.Buffer.copyData`で埋めたもの）に複製します。以後は各々が自分の状態を持つので、片方を
変更するまでは同一の出力を出します。

`newIOGen`は呼び出し側が選んだ`Bits64`のシードを、splitmix64（Vigna、パブリックドメイン）の
1ステップ（`Xoroshiro64StarStar`、64ビット状態）または2ステップ（`Xoroshiro128PlusPlus`、
128ビット状態）で完全な状態へ展開します。拡散の悪い状態や全ゼロの状態をアルゴリズムに渡さない
ためで、参照実装自身のヘッダコメントが勧めるシード方法そのものです。`nextDouble`は1ステップの
出力を、生成器自身のネイティブな精度（`output / 2^32`または`output / 2^64`）で`[0,1)`の一様な
`Double`に写します。他の生成器の一部が提供する、`Double`の仮数53ビット分の乱雑さではありません。
`newSeeded`は、単調クロックにプロセスIDを混ぜた値（`System.Clock`/`getPID`）をシードにする
便宜的なコンストラクタです。暗号論的に安全ではなく、「実行のたびに同じ列を渡さない」程度の
妥当な既定にすぎません。再現できる、呼び出し側が選んだシードが必要なら、`newIOGen`を直接
使ってください。

`jump`/`longJump`/`jumpCE`/`jumpN`は参照アルゴリズム自身のジャンプ先送りの仕組みを包み、
`next`を`2^k`回（または`c * 2^e`回、あるいは呼び出し側が与える任意の距離だけ）実際に
踏まずに、生成器の状態を進めます。独立した並列計算へ重ならない部分列を配るのに役立ちます。
`jumpN`の距離は、`Xoroshiro64StarStar`（状態全体が64ビット）では`Bits64`1語、
`Xoroshiro128PlusPlus`（128ビット）では2語です。参照アルゴリズム自身の一般的な
`POLY_WORDS`語の`jump[]`配列（この2つより大きな状態の生成器向け）より単純にしてあります。

各モジュールには、別に単一のグローバル生成器（`setSystemSeed`/`nextIO`/`jumpIO`/`longJumpIO`/
`jumpCEIO`/`jumpNIO`）も用意してあります。状態はすべてC側の静的変数（各`support/c/*.c`の
`system_seed[...]`）に置いてあり、スレッド安全ではありません。共有する可変状態に
ロックがありません。上のインスタンスごとのAPIが呼び出し側に任せる「自分の`IOGen`は自分で
守る」という約束よりもさらに緩いものです。Cの`rand()`/`srand()`のように、持ち回す
インスタンスなしで手早く使うための便宜として提供しているだけです。並行処理や再現性が必要な
用途には、`newIOGen`と`next`を使ってください。

この単一グローバル生成器という設計は、一見もっと簡単な代案への答えでもあります。代案とは、
トップレベルの`unsafePerformIO`で作った`IOGen`で、呼び出し側にハンドルを引き回さなくて
済むものです。rc2も上流のRefCも、引数が0個のトップレベル定義（CAF）を、たとえばGHCのように
メモ化することはありません。どちらも参照のたびに本体を新たに呼び直します（`Compiler.RC2.Emit`と
上流`Compiler.RefC.RefC`の`nargs == 0`の扱いで確認済みです）。そのため、トップレベルの
`unsafePerformIO (newIOGen ...)`の形のCAFは、参照のたびに、独立にシードされ、独立に
`Buffer`を確保された*新しい*`IOGen`を黙って返し、共有された1つにはなりません。つまり
このバックエンドでは、ChezやJSでなら可能かもしれないメモ化されたトップレベルのシングルトンは
使えません。上の`*IO`関数群はこれを避けて、IdrisのCAFの裏ではなくC側の静的変数に状態を
置いています。トップレベルの`IOGen`を包む薄いIdrisのラッパではなくCで実装しているのは、
まさにそのためです。

`Xoroshiro128PlusPlus`の以前の版は、同じモジュール名でも別のアルゴリズム（4個の`Bits32`状態から
32ビットを出力するxoshiro128++）を実装していて、Cのラッパではなくゼロから書いた純Idrisの
移植でした。手で引き回す純粋な`Gen`レコード（`seed`/`next`/`nextDouble`）と、`IORef`ベースの
便宜的なラッパ（`nextBits32`/`nextDoubleIO`/`newSeeded`）を持っていました。その実装は、上で
移植した本物のxoroshiro128++に丸ごと置き換えました。「128」と「++」の名前が共通なだけの
別のアルゴリズムであり、単なる名前の付け替えではありません。

### `Data.Double.RC2`

上流`Data.Double`の`unitRoundoff`/`epsilon`/`nan`/`inf`へのパッチです。これらはいずれも
`"scheme:..."`/`"node:..."`の`%foreign`タグしか持たないため、refcやrc2（どのCバックエンドでも）
では全く使えません（`TODO.md`の同じ「Upstream stdlib `%foreign` declarations...」の項目を
参照）。`rc2/support/rc2/numeric.h`には、流用できるものが無かったため、4つの小さな新しい
`static inline`関数`idris2rc2_unitRoundoff`/`idris2rc2_epsilon`/`idris2rc2_nan`/
`idris2rc2_inf`が必要でした:

```c
static inline double idris2rc2_unitRoundoff(void) { return DBL_EPSILON / 2.0; }
static inline double idris2rc2_epsilon(void)      { return DBL_EPSILON; }
static inline double idris2rc2_nan(void)          { return NAN; }
static inline double idris2rc2_inf(void)          { return INFINITY; }
```

値は、思い込みではなく上流自身のChezの定義（`idris2-src/support/chez/support.ss`）と
突き合わせてあります。`blodwen-calcFlonumUnitRoundoff`は、`1.0 + uro == 1.0`が初めて成り立つ
まで値を繰り返し半分にします。これは最近接偶数丸めの古典的な境界で、IEEE 754 binary64では
ちょうど`DBL_EPSILON / 2`に収束することが証明できます。`epsilon`はそのちょうど2倍
（`DBL_EPSILON`そのもの。`1.0`に足したときに`1.0`を変えない*ことのない*最小の値）です。
このモジュール自身のテスト（`tests/TestDoubleRC2/TestDoubleRC2.idr`）は、リテラルを
ハードコードして比べる代わりに、これらを定義づける性質を直接検査します
（`1.0 + unitRoundoff == 1.0`、`1.0 + epsilon != 1.0`、`epsilon == unitRoundoff * 2`、
加えて`nan != nan`と`1.0 / inf == 0.0`）。

これらは上流ではいずれも、`PrimIO Double`ではなく素の`Double`として宣言された、引数0個で
モナドではない`%foreign`の値です。この形は、これまでのrc2やrc2baseの`%foreign_impl`パッチの
どれも使っていませんでした。このモジュールを本番で書く前に、単独の試作プログラムを実際に
コンパイルして実行し（コンパイラのソースを読んだだけでなく）、動くことを確認しました。
このバックエンドの他の引数0個のトップレベル定義と同様に、この4つの呼び出しは、CAFとして
メモ化されず、参照のたびに新たに評価されます（rc2も上流RefCも、ChezやGHCのように引数0個の
トップレベル定義をメモ化することはありません。*状態を持つ*生成器の場合に同じ非メモ化の
挙動が実際にはバグになってしまう点については、上の`System.Random.Xoroshiro128PlusPlus` /
`System.Random.Xoroshiro64StarStar`の節を参照）。ここで無害なのは、4つとも副作用のない純粋な
定数だからです。`idris2rc2_inf()`を2回評価しても、どちらも同じ`INFINITY`を返します。

タグは`"RefC:"`ではなく`"RC2:"`です。これらのシンボル名はrc2自身のランタイムに加えた
rc2専用の新規の追加であり、本物の`idris2 --cg refc`のビルドのランタイムがたまたま
提供しているものではないためです。

### `Data.Double.Convert`

`TODO.md`の「Performance: `Double <-> String` cast has no fast path」の項目が、修正の方向を
示していました。rc2自身の`cast {to=Double}`/`cast {to=String}`
（`rc2/support/rc2/numeric.c`の`idris2rc2_parse_double`/`idris2rc2_shortest_double`）は
正しく、ロケールにも依存しませんが、呼び出しのたびにGMPの多倍長の一時値の費用を払います。
`fastParse`/`fastShow`は、この2つのキャストだけに対する**任意利用**の置き換えです
（全域な意味論は同じです。解析できない入力は`0.0`になり、`nan`/`inf`/`-inf`/`-0.0`と
最短で往復できる10進表記という出力の形も同じです）。`cast`自体は変えず、常に正しい低速な
経路のままです。

どちらの方向も、よく知られた表引きの高速な計算（解析にはEisel-Lemire、整形にはDiyFp/Grisu2
系のスケール済みの桁生成）を、素の`uint64_t`/`__uint128_t`の算術だけで行い、GMPは使いません。
ただし、この高速な計算自身の誤差の見積もりが少しでも疑わしいところでは、最後の1ビットの余裕を
削ろうとせず、上の正確な関数（この再利用のために`numeric.c`/`numeric.h`で非`static`に
公開してあります）へ丸ごと任せます。

整形器の正しさは、桁生成が正確であることにはそもそも頼っていません。頼れないというのは、
次の意味です。Grisu2系のループは`v`自身ではなく`v`の上側の*境界*から桁を生成し、
最後に落ち着く「最後の桁」は出発点の推測にすぎず、真の値から2以上ずれることもあります
（開発中に直接確認しました）。往復の確認だけでは、これを常に捕まえられるとも限りません
（特に極端な大きさでは、隣り合う複数の10進文字列が、まったく同じ`Double`に解析し直される
のがふつうなので、「往復できる」ことは「`idris2rc2_shortest_double`が出すはずの
その桁である」ことを意味しません）。そこで整形器は、生成された桁を単独では決して
信用しません。小さく限られた近傍を探して（これも`idris2rc2_fastParseDouble`の呼び出しだけで、
GMPは使いません）往復できる候補を見つけ、それがそこで**唯一**であること、つまり両隣のどちらも
往復できないことを確かめてから受け入れます。これほど近くに往復できる候補が複数ある値
（上と同じ極端な大きさの場合）は、この唯一性の検査に落ちて、丸ごと元の関数へ戻ります。
これは最初から設計したのではなく、経験的にたどり着いたものです。正確な関数を相手にした
500万ケースのファズ実行で、まず窓の位置のバグ、次にスケール済みの10進指数の復元の符号の
誤りとそれに関連する桁数のバグ、そして最後にこの最後の桁の正しさの穴そのものが見つかりました。
それぞれの修正の理由づけは、コードのコメント（`double_convert.c`の
`fast_shortest_double`/`digit_gen`）に残してあります。どれも、いったん正しく見えるまま
出荷されかけた実際の失敗の型を記録したもので、単なる設計上の選択ではないためです。

2つの引き表（解析側の約650エントリの128ビットの5の冪、整形側の約87エントリの64ビットの
キャッシュ済み10の冪）は、論文から手で写したものではなく、正確なGMP計算で生成し
（`libs/rc2base/support/c/gen_double_tables.c`。文書化された一度きりのツールで、通常の
ビルドには含まれません）、`pow5_table.h`/`cached_powers.h`としてコミットしてあります。

`fastShow`のネイティブ関数`idris2rc2_fastShowDouble`は、完全に組み立てた`IDRIS2RC2_String`を
直接作ります（`idris2rc2_mkEmptyString`。`Data.String.RC2`や`Data.TextBuffer`がすでに使っている
のと同じ、1回の確保で済ませる手法）。一時バッファに整形してから`String`型の`%foreign`の
戻り値にもう一度コピーさせる方法は取りません。

### `Data.Integer.GMP`

本物のGMPの`mpz_*`関数への直接の`%foreign`バインディングです。可能になったのは、
`Compiler.RC2.Emit`自身が、`Integer`を`%foreign`の引数と戻り値に使う対応を持っているからです
（`rc2/tests/Test118FFI/FFIInteger.idr`。以前の`Test55FFIIntegerReturn.idr`もここに吸収
しました）。このランタイムで普通のIdrisの`Integer`をすべて裏づけている`mpz_t`そのものが、
本物のGMPのシンボルへ直接渡され（引数の場合）、または新規に確保されます（戻り値の場合は、
暗黙の先頭の出力引数として。GMP自身の「`rop`が常に最初」という規約、`mpz_add(rop, op1, op2)`
などにそのまま一致します）。このモジュールのどこにも、専用のラッパは要りません。

2つのグループと3つのその場変更関数があり、`mpz_`を落として、snake_caseを機械的にcamelCaseに
しただけで、見た目のための改名はしていません。**算術・ビット演算**
（`add`/`sub`/`mul`/`neg`/`abs`/`addUi`/`subUi`/`uiSub`/`mulSi`/`mulUi`/
`gcd`/`lcm`/`tdivQ`/`tdivR`/`fdivQ`/`fdivR`/`cdivQ`/`cdivR`/`mod`/
`divexact`/`powUi`/`uiPowUi`/`powm`/`powmUi`/`sqrt`/`mul2exp`/
`tdivQ2exp`/`tdivR2exp`/`fdivQ2exp`/`fdivR2exp`/`and`/`ior`/`xor`/`com`/
`setbit`/`clrbit`/`combit`/`nextprime`)と、**述語・問い合わせ**（`cmp`/`cmpabs`/
`probabPrimeP`/`perfectSquareP`/`perfectPowerP`/`popcount`/`hamdist`/
`tstbit`/`sizeinbase`/`fitsSlongP`/`fitsUlongP`/`getD`/`scan0`/
`scan1`）です。すべて`namespace GMP`の中にあり（`GMP.add`のように使います）、修飾なしでは
エクスポートしません。そうしないと、これらの名前のうち十数個が`Prelude`自身の名前
（`abs`、`neg`……正確には`negate`、`mod`、`gcd`、`lcm`、`sqrt`、`and`、`xor`）と衝突して
しまうためで、`System.FFI.C.Ptr`の型ごとの名前空間がすでに使っているのと同じ規約です。

意図的に除外したものがあります。いずれも、その関数の実際のシグネチャが上の2つの形
（`void`を返し、先頭に`mpz_t`の出力引数が1つある形、または出力引数がなく素のネイティブ値を
返す形）のどちらにも合わないためです。無理に当てはめると、実際の情報を黙って捨てたり、
引数の数を数え違えたりすることになり、確立した規約に従うだけでは済みません。

- `mpz_invert`/`mpz_root`: 先頭の`mpz_t`の出力引数を持ちながら、同時に意味のある
  `int`の戻り値（可逆かどうか、厳密かどうか）も返します。
- `mpz_tdiv_qr`/`mpz_fdiv_qr`/`mpz_cdiv_qr`/`mpz_gcdext`: 出力引数が複数あります。
- `mpz_urandomb`/`mpz_urandomm`とGMPの乱数API全般: 独自のinit/clearのライフサイクルを持つ
  不透明な`gmp_randstate_t`が要り、別の設計作業になります。
- `mpz_get_str`/`mpz_set_str`: Idris自身の`Integer`の`Show`や数値リテラルの解析と重複します。
  それらはすでに、これと同じ`mpz_t`を通っています。

`setbit`/`clrbit`/`combit`は単一の`mpz_t`をその場で変更するので、先に出力引数へコピー
するカンマ式（`(mpz_set($r, $1), mpz_setbit($r, $2))`）として束縛しています。引数は
変更されません。

`tests/TestIntegerGMP/TestIntegerGMP.idr`はすべてのバインディングを少なくとも1回は実行し、
Idris自身のネイティブな`Integer`算術（同じ`mpz_t`の状態を、まったく別の経路で計算したもの）、
または教科書的な既知の定数（`gcd 1071 462 == 21`、定番のべき乗剰余の例
`4^13 mod 497 == 445`など）と突き合わせて検証します。値は一貫して`Int`の64ビット範囲を
大きく外れた大きさにしています。

### `Language.RCExpr.AST`/`Lexer`/`Parser`

`--directive dumprcexpr`の`.rcexpr`ダンプ形式（`idris2-rc-cg`の`rc2`パッケージ内の
`Compiler.RC2.Pretty`。この文法の唯一の正本です）のための、独立したパーサです。
`tools/rcexpr-lint`（解析した木に対する所有権の異常の検査器。`Compiler.RC2.Sink`の
use-after-freeを見つけるのに、ダンプを手で何時間も追う羽目になったあとに作りました）の
ために作りましたが、パーサはコンパイラに依存せず、この形式を読みたい他のツールでも
再利用できるので、`rc2`本体ではなくここに置いてあります。

- `Language.RCExpr.AST` -- 解析結果の表現です。`Pretty.idr`の`prettyExp`/`prettyDef`の
  節ごとに、コンストラクタが1つあります。このプロジェクトが所有しない*上流*の`Show`
  インスタンス経由でしか出力されないフィールド（定義やコンストラクタの`Name`、`PrimFn`、
  `Constant`、コンストラクタ自身の`ConInfo`やタグ）は、深く解析せず不透明な`String`として
  取り込みます。診断で表示し直すには十分に正確ですが、意味を解釈することはありません。
  `RCLocal`自身（`vN`/`_`/`[__]`/`#...`）は、所有権の追跡に本物の同一性が要るので、
  正確に解析します。
- `Language.RCExpr.Lexer` -- インデントを取り除いた1行ずつをトークンに分けます（行や
  インデントの構造は、素の`String`に対して`Parser`自身が別に扱います）。
  `Language.JSON.Lexer`と同じ、上流の`Text.Lexer`を使います。
- `Language.RCExpr.Parser` -- `parseProgram : String -> Either ParseError RCProgram`。
  外側の木の形はインデントが決めます（`Pretty.idr`の`indent n`は常にちょうど`2*n`個の
  空白です）。各行の内容は、`Lexer`のトークン列に対して上流の`Text.Parser`の
  コンビネータで解析します。上流の`Show`インスタンスのいくつかは、トークン数が固定の
  単純な読み取りに合わないことが分かりました（`Core.Name`の表示は、ソース位置の
  `at <FC>`が末尾に付いたり、演算子の名前が`(...)`で包まれたりします。`CFType`の
  `Show`は、`CFFun`/`CFStruct`/`CFUser`では再帰的で引数の数も可変です）。
  `greedyWordsG`が、次のトークンが構造上の境界らしく見えるまで、名前の形のトークンを読み
  続けます。こうしたものに対する一般的な逃げ道です。

`tests/TestRcexprParser/TestRcexprParser.idr`は、rc2自身の`refc-suite`の実際のダンプに
対してこれを作る途中で実際にぶつかった、あらゆる厄介な形を網羅するように手書きした
`.rcexpr`のサンプルから作った回帰テストです。一覧は、テスト自身のモジュールの注記を
参照してください。そこには、このパーサ自身が持っていた`dup vN xM`の数え違いも含まれます
（個数は2つの別トークンではなく`x`に貼り付いた1トークンです）。これは、`rcexpr-lint`が
他は正しいプログラムで誤検出を出したことで発覚しました。

## `Network.HTTP.Server`: 最小限のイベント駆動HTTPサーバ

シングルスレッドの`epoll`駆動HTTP/1.1サーバです（生のイベントループが`System.Linux.Epoll`、
バイナリ安全なバッファのソケットIOが`Network.RC2`、その上のHTTPの論理が
`Network.HTTP.Server`）。1回の呼び出しで起動します。各リクエストには戻り値ではなく
継続で応答するので、`Handler`は同期的に応答することも、継続を取っておいて後で
（別スレッドからでも）応答することも、ループを`stop`することもできます。リクエストと
レスポンスのボディは生の`Data.Buffer`のバイト列で、バイナリ安全です。`Response.*`の
コンストラクタ（`text`/`html`/`json`/`ok`/`notFound`/`bytes`/...。そのまま呼ぶか、
名前が衝突するときは`Response.`で修飾します）でレスポンスを作ります。いずれも、先頭に
省略可能な暗黙の`headers`を取ります。

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

Linux専用（`epoll`）です。リクエスト行、ヘッダ、`Content-Length`のボディ、keep-aliveに
対応し、`chunked`、HTTP/1.0、TLS、パイプライン処理のレスポンス順序には対応しません。読み取り
アキュムレータには上限があります（`serve`の`maxRequestBytes`、既定は8 MiB）。大きすぎる
リクエストは、応答なしで捨てられます。完全な設計と、このモジュール自身のテストプログラムが
ぶつかった正しさの落とし穴（重要です）は、`doc/http-server.md`を参照してください。落とし穴とは、
トップレベルで`unsafePerformIO`した`IORef`が、`--cg chez`ではメモ化されるのに、`--cg rc2`
（上流の`--cg refc`も同様）ではメモ化**されない**ことです。参照のたびに、共有ではなく
新しい`IORef`が黙って作られます。このパターンで`Handler`をまたいで状態を共有してはいけません。
代わりに、`main`で`IORef`を作って渡してください。

## `Network.HTTP.Route`/`Router`: 型安全なルートテーブル

キャプチャが生む型で添字づけたパスのパターンと、その上のExpress風のルートテーブルです。
`router`は`List RouteEntry`から素の`Handler`を直接作るので、ほかに何も変えずに
`serve`へ差し込めます:

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

キャプチャが`n`個あるルートには、型`ty1 -> ... -> tyn -> (Response -> IO ()) -> IO ()`の
ハンドラが必要で、これはコンパイル時に検査されます。`FromSegment`の解析失敗（または
リテラルのセグメントやメソッドの不一致）は、クラッシュせず、次に登録されたルートへ
素通りします。`capture`が、固定セグメントのように`//`で連ねるのではなく関数呼び出しとして
入れ子になる理由、およびパスの分割が文字列を1回走査するだけ（`strSubstr`による再走査が
ない）である理由を含む完全な設計は、`doc/http-router.md`を参照してください。

## `Network.URL`: URLの解析・構築とパーセントエンコード

`Network.HTTP.Router`が扱わないもの、つまりクエリ文字列とその下にあるパーセントエンコード、
および最善努力のURL分割です。純Idrisで、FFIはありません。

```idris2
import Network.URL

percentDecode "a%20b"                       -- "a b"
parseQuery "?q=two+words&lang=en"           -- [("q","two words"),("lang","en")]
buildQuery [("q","a b"),("n","1+2")]        -- "q=a+b&n=1%2B2"

parse "https://ex.com:8443/a%20b?x=1#top"
-- MkURL (Just "https") (Just "ex.com") (Just 8443) "/a%20b" [("x","1")] (Just "top")
render it                                   -- URL文字列に戻します
pathSegments "/a%2Fb/c/"                    -- ["a/b", "c"]
```

`parse`は常に成功します（最善努力であり、検証器ではありません）。スキーム相対の
`//host/p`、パスだけの`/p?q#f`、IPv6のホストリテラルを扱い、`userinfo`は捨てます。
`%XX`のエスケープはUTF-8のストリームとして復号します（`%C3%A9`は`"é"`の1コードポイント、
不正なバイトはU+FFFD）。これは`Text.Encoding.UTF8`経由です。`doc/url.md`を参照して
ください。

## `Text.Encoding.UTF8`: UTF-8とコードポイントの相互変換

`decode : List Bits8 -> List Char` / `encode : List Char -> List Bits8`
（と`encodeChar`）です。rc2の`pack`/`unpack`はすでにコードポイント単位です（Chezと同じく
通信上はUTF-8）。これは、生のUTF-8の*バイト列*（ソケットから、`%XX`の列から、`Buffer`から）
を持っていて、`pack`が欲しがるコードポイントのリストが必要なとき、またはその逆のときの
ための部品です。厳密に処理し、過長な表現、サロゲート、途中で切れた列は、それぞれ1つの
U+FFFDに復号されます。`Network.URL`が使っています。`tests/TestURL/`で検証しています。

## `Data.String.RC2`: バイト単位の`String`アクセス

```idris2
unsafeStringByteSlice : (s : String) -> (off, len : Int) -> String  -- バイトオフセット。コードポイントではない
byteLength            : String -> Int                               -- 通信上のバイト数。コードポイント単位の`length`とは別
```

rc2の他の`String`プリミティブ（`substr`、`strIndex`、`length`など）はすべてコードポイントを
数えます。`unsafeStringByteSlice`は例外で、実際のバイト`[off, off+len)`を返します。範囲が
生のバイトオフセットで届くとき（POSIXの`regexec`、長さ接頭辞つきのフィールド）に使います。
コピーは1回で、`String`値を直接作ります（Cシムが完成した値を返し、Idris側は`believe_me`で
そのまま通します。2回目のマーシャリングのコピーはありません）。「Unsafe」とあるのは、
`off`/`len`が`s`のバイト長に丸められる（メモリ安全で、クラッシュはしません）一方、
コードポイントの途中で切ると、読み戻したときにU+FFFDとして読まれるバイトが残るためです。
どちらも埋め込まれたNULバイトを保ちます。`byteLength`は`IDRIS2RC2_String`自身の`len`
フィールドを直接読み（`static inline`のC関数で、`byteLength`自体も`%inline`なので、
`strlen`呼び出しではなくフィールド読み出しにコンパイルされます）、
`unsafeStringByteSlice`は最初のNULまでではなく、その同じ`len`で切り出します。
`Text.Regex.POSIX`が使っています。`tests/TestStringRC2/`を参照してください。

## `Text.NumberFormat`: 固定幅の16進表記

`toHex`は、値をその型の幅と同じ桁数の小文字の16進で表し、左をゼロ詰めします。
`Bits8`/`Int8`は2桁、`Bits16`/`Int16`は4桁、`Bits32`/`Int32`は8桁、
`Bits64`/`Int64`/`Int`は16桁です。符号つきの型は2の補数のビットパターンを表示します
（`the Int8 (-1)`は`"ff"`）。符号なしの型はその大きさそのものです。
`digit : Bits8 -> Char`は1ニブル分の段で、桁を自分で並べたいときに使います。すべて純粋で、
Cシムはありません。`tests/TestNumberFormat/`を参照してください。

```idris2
import Text.NumberFormat

toHex (the Bits8 0x0a)      -- "0a"
toHex (the Bits64 0xdead)   -- "000000000000dead"
toHex (the Int8 (-2))       -- "fe"
```

## `Text.Regex.POSIX`: libcの`<regex.h>`へのバインディング

`regcomp`/`regexec`/`regfree`/`regerror`によるPOSIX正規表現です。外部依存はありません
（libcに入っています）。

```idris2
import Text.Regex.POSIX

Right re <- compile "([a-z]+)=([0-9]+)"           -- 既定はERE。BREは`compile {flags = bre}`
  | Left msg => ...                               -- 構文として不正なパターン

matches re "x foo=42 y"                           -- True
match re "x foo=42 y"                             -- Just [Just "foo=42", Just "foo", Just "42"]
matchAll re "a=1 b=22"                            -- [[Just "a=1", ...], [Just "b=22", ...]]
replaceAll re "\\1:\\2" "a=1 b=22"                -- "a:1 b:22"
```

`compile`は`IO (Either String Regex)`で、`match`/`matches`/`matchAll`/`replace*`は
純粋です。グループの要素が`Nothing`なのは「参加しなかった」ことを表し、`Just ""`とは
区別されます。範囲はバイトオフセットで、`Data.String.RC2.unsafeStringByteSlice`で切り出す
ので、`match`/`matchAll`/`replace*`はマルチバイトの対象文字列でも正しいバイトに当たります。
パターンの意味論（`.`、`[[:alpha:]]`、`ignoreCase`）は、プロセスがUTF-8ロケールで動いている
ときにコードポイント単位で照合します。rc2のランタイムは起動時に
`setlocale(LC_ALL, "")`を行うので、UTF-8互換の環境ロケール（`C.UTF-8`、`*.UTF-8`）が
必要です。UTF-8でないロケールでは、ロケール由来の文字列が壊れます（トップレベルの
`README.md`を参照）。素の`C`ロケールでは、バイト単位・ASCIIのみの照合になります。
注意点: 入力はNUL終端として扱われます（`\0`で検索が終わります）。最左最長の意味論です。
名前つきグループはありません。`doc/regex-posix.md`を参照してください。

## RE2による正規表現: `text-re2`

RE2のバインディング（`Text.Regex.RE2`。線形時間で、機能も多い）は、かつてここにある
モジュールでした。`rc2base`を素のCツールチェーンでビルドできるように、`libs/text-re2`
（パッケージ`text-re2`）へ移しました。RE2はC++で、`g++`・`pkg-config`・abseilが必要です。
1つのモジュールのために、このライブラリ全体のビルド依存にすべきではないからです。
`-p rc2base -p text-re2`を加えたうえで`import Text.Regex.RE2`してください（`Data.String.RC2`を
使います）。`libs/text-re2/README.md`を参照してください。
