# `System.IO.Uring`

*[English](iouring.md)*

Linuxの非同期I/Oインターフェース`io_uring`に対するIdris2バインディング。生の
`io_uring_setup`/`io_uring_enter`システムコールを直接使うのではなく、
[liburing](https://github.com/axboe/liburing)経由で実装しています。
`idris2-rc-cg`自身の`rc2`バックエンド専用です。

## なぜ生のシステムコールではなくliburingなのか

`io_uring_setup`/`io_uring_enter`/`io_uring_register`自体は本物ですが低レベルな
ABIです——呼び出し側がsubmission/completionリングバッファのmmapを自分で行い、
メモリオーダリング的に正しいproducer/consumerインデックス更新を手で計算し、
実行中のカーネルが実際にどのショートカットに対応しているかを`IORING_FEAT_*`
フラグで追跡する必要があります。liburingはまさにそのブックキーピングを行う
リファレンスC実装であり、実世界のio_uring利用者(`glib`、`.NET`、Rustの
`tokio-uring`など)のほとんどが間接的に依存しています。リング用プロトコルを
システムコールの上にゼロから、Idris側のシムとして再実装しても、このパッケージ
自身が必要とするスコープには何の得もなく、しかも将来カーネルに`IORING_FEAT_*`
が追加されるたびに手動で追従し続ける必要が出てきます。

## なぜ大部分が`liburing.h`へ直接バインドでき、シムが不要なのか

このパッケージを書き始める前に実証済み(`nix-shell -p liburing gcc --run 'gcc
test.c -luring'`——実際にリングのinit/submit/waitを一往復させるテスト)であり、
以下の実際の`%foreign`バインディングでも改めて確認しています: liburing自身の
利便性API(`io_uring_get_sqe`、すべての`io_uring_prep_*`、
`io_uring_sqe_set_data64`、`io_uring_submit(_and_wait)`、
`io_uring_{wait,peek}_cqe`、`io_uring_cqe_get_data64`)は、ほぼ全て
`<liburing.h>`内で直接`static inline`宣言されており、`liburing.a`/`.so`側には
リンク可能なシンボルが一切ありません。`Compiler.RC2.Emit`は、すべての
`%foreign`宣言が指すヘッダを、*呼び出し側自身*が生成する`.c`ファイルへ既に
直接`#include`しています(該当モジュール自身の`emitHeaderFiles`隣接の
ドキュメントコメント参照)——本物のライブラリ間呼び出しが必要とするような、
別個の翻訳単位ではありません——そのため`static inline`関数の本体はそのまま
可視であり、Cコンパイラがその場で呼び出しをインライン化します。これらに関しては
シムのラッパーも、`.o`/`.a`の関与も一切不要です。

これは`libs/notcurses/doc/notcurses.md`が`notcurses.h`自身の`static inline`
関数について、*それでもなおシムが必要*という結論に至るまでに詳しく辿った理路と
同じものです——違いは、notcursesのシムが最終的に何の*ために*必要だったかという
点です: 主に構造体をポインタ渡しで組み立てる必要(`notcurses_options`、
`ncplane_options`)と、非公開マクロから導出される定数(`NCKEY_*`)でした。
`liburing.h`自身のprep関数群は、引数を素朴なスカラ値(`int fd`、`void *buf`、
`unsigned len`など)としてSQEへそのまま渡すだけで、それに類するオプション構造体
の手順がありません——そのためこのパッケージのシムはずっと小さくなり、必要なのは
以下に挙げる部分だけです。

## それでも(小さな)シムが存在する理由

1. **`io_uring_queue_init(entries, struct io_uring *ring, flags)`**は、
   *呼び出し側*が既に非自明なサイズの`struct io_uring`(リング自身の
   ブックキーピング用に mmap される構造体)の記憶域を所有していることを
   前提としています——Idris側にはそれを自力で置く場所がありません。
   `idris2rc2_iouring_queue_init`はヒープにそれを確保してポインタを返します
   (失敗時は`NULL`——`libs/notcurses`自身の`init`と同じ`Maybe`形の契約です)。
   対になる`idris2rc2_iouring_queue_exit`が、それを解体・解放します。
2. **`io_uring_wait_cqe`/`io_uring_peek_cqe`**は、結果を`struct io_uring_cqe
   **`というout引数経由で書き込みます——「ローカル変数のポインタのアドレスを
   置く場所がない」という、`%foreign`には答えのない同じ問題です。本当に成功
   した呼び出しがNULLのcqeを返すことは決してないので、
   `idris2rc2_iouring_wait_cqe`/`_peek_cqe`は`(戻り値, out引数)`を「`NULL`は
   失敗/未準備を意味する」という単一の戻り値へ畳み込んでいます——どちらも
   このパッケージ自身のヘッダ内で`static inline`のままです。`.o`は関与せず、
   liburing自身の既にインライン化された本体を組み替えているだけです。
3. **`io_uring_prep_accept`の`addr`/`addrlen`out引数**(相手側アドレス)にも
   同じ形の問題があります。`idris2rc2_iouring_prep_accept_simple`は常に
   `NULL`/`NULL`を渡します——このパッケージは相手側アドレスを一切公開しません
   (必要な呼び出し元は、結果のfdに対して後から`getpeername`すればよいです)。
4. **`io_uring_prep_connect`の`addr`引数**には、host/portのペアから組み立てた
   本物の`struct sockaddr`が必要です——これは本当の作業です(`getaddrinfo`で
   ホスト名または数値アドレスをIPv4/IPv6として解決する処理で、素のinline
   ラッパーにできることではありません)。`idris2rc2_iouring_make_sockaddr`は
   実際にコンパイルされる関数です(`iouring_util.c`——このシム全体の中で唯一
   本当にinlineでない部分)。`idris2rc2_iouring_sockaddr_family`/`_len`
   (どちらも`static inline`で、`sockaddr`自身の`sa_family`フィールドを読む
   だけ)は、2つ目のout引数を使わずに、`io_uring_prep_connect`が必要とする
   `addrlen`をIdris側で計算できるようにしています。
5. **`io_uring_cqe`自身の`res`/`user_data`/`flags`フィールド**には、
   liburing.h内に専用のアクセサがありません(`user_data`専用の
   `io_uring_cqe_get_data64`だけは既に直接使っています)——
   `idris2rc2_iouring_cqe_res`/`_flags`は1行の`static inline`フィールド読み
   出しで、`res`と同じ形です。

上記のいずれも、本物の「別翻訳単位呼び出し」型シム(`libs/notcurses`自身の
`idris2rc2_nc_get_blocking`/`_get_nonblock`——ファイルスコープの`static`
キャッシュを1つ共有しており、翻訳単位ごとに複製されると黙って壊れる類のもの)
を必要としませんでした——ここにある関数はどれも純粋なフィールド読み出しか定数
であるか、あるいは(sockaddrビルダーの場合)気にすべき共有可変状態が無いため、
このパッケージ自身のヘッダ内で`static inline`にしても安全であり、
`queue_init`/`_exit`とsockaddrビルダー以外は`.o`/`.a`のリンクステップを
完全に回避できます。

## なぜ`iouring_util.h`は素朴な`#include <liburing.h>`だけで済むのか

`notcurses.h`とは違い(`libs/notcurses/doc/notcurses.md`自身の「なぜ
`nc_util.h`は本物のヘッダを一切includeしないのか」節を参照)、`liburing.h`
には、呼び出し側がまだ持っていないようなglibcの機能テストマクロを必要とする
箇所は見つかりませんでした——このパッケージ自身の`tests/verify.sh`が、追加の
`IDRIS2_CFLAGS`なしで実際にこれに対してコンパイル・リンクできていることで
確認済みです。将来のliburingバージョンでこれが変わった場合の対処法は、あちらの
文書に書かれているのと同じものです: 呼び出し側へ本物のヘッダを渡すのをやめ、
必要な分だけを手で宣言し、本物の`#include`はこのシム自身の`.c`ファイル内へ
閉じ込める、という方法です。

## 設計上の判断

- **`URing.pending`/`pendingAddrs`は、進行中のバッファ/sockaddrを、リング
  自身の全生存期間にわたって生かし続けます。** このパッケージを書いている間に
  実際に踏んだ*本物の*バグであり、仮定の話ではありません——同じ根本原因が、
  2つの異なる姿で2度現れました:
  1. `prepWrite`の最初のバージョンは`URing`引数を取らず、何も保持していません
     でした。実際に`openat`+`write`+`read`での読み戻しを行うテストが、毎回
     壊れた/文字化けしたファイル内容を生成していました。根本原因は——
     `io_uring_prep_write`はバッファポインタをSQE上に*保存する*だけで、
     カーネルは*後になってから*(`submit`自身が行う`io_uring_enter`
     システムコールの中、さらに一般にはその操作の完了(completion)が実際に
     現れるまでの間、カーネルがそれを読み書きし続けている可能性がある)それを
     読みに来ます——しかしrc2自身の所有権解析には、`void`を返す、rc2から
     見れば完全に不透明な外部呼び出しが、返った後もその引数を「使い続けて
     いる」ことを知る術がなく、`prepWrite`の`Buffer`引数を完全に消費済みと
     見なして即座に解放してしまい、カーネルがそこへたどり着くよりずっと前に
     メモリが失われていました。
  2. `prepConnect`の最初のバージョンは、`io_uring_prep_connect`の直後に
     自分の`sockaddr`を即座に解放していました。理由は(誤って——
     `iouring_util.h`自身の、今は訂正済みのコメントを参照)、カーネルはprep
     の時点でアドレスをコピーするはずだ、という思い込みでした——実際の
     ループバックTCPテストでは、connectが毎回`-EAFNOSUPPORT`で失敗していま
     した(カーネルが、既に`free`済みのメモリをsockaddrとして読んでいた
     のです)。(1)とまったく同じ形のバグで、違いはrc2で参照カウントされる
     `Buffer`ではなく、このパッケージが直接所有する`malloc`済みメモリの上で
     起きたという点だけです。

  どちらも同じ方法で修正しました: カーネルへ「後で使う」ポインタを渡す
  `prep*`関数はすべて、追加で所有元の`URing`を要求するようになり、渡した
  ものを`URing`自身が持つ`IORef`のどちらか(バッファ用の`pending : IORef
  (List Buffer)`、sockaddr用の`pendingAddrs : IORef (List AnyPtr)`)へ
  格納するようになりました——呼び出し元自身のコードがその後どう振る舞おうと
  生き残る、ライブラリ側が保持する2つ目の参照です(生きた`Buffer`参照、
  あるいは文字通り`free`を先送りする形)。トレードオフとして、どちらも
  `URing`全体が(`exit`が両方のリストをdrop/free)片付くまで回収されません
  ——精密ではありませんが、正しく、しかもAPI利用者側の協力を一切必要と
  しません((1)の以前の壊れた設計にも、実は使える回避策はありました——
  `buf`への何らかの後続の参照を自分で保持しておけば、rc2の通常の「最初の
  出現でmove、以降の出現はdup」という所有権規則がそれを守ってくれます——
  しかしそれは呼び出し側が覚えておかなければならない、忘れやすい落とし穴で
  あり、このパッケージが黙って頼ってよいものではありません。(2)には
  そもそも同等の呼び出し側での回避策すらありません。生の`malloc`済み
  ポインタは、そもそもrc2の参照カウント対象ではないからです)。
- **一度に1件のcompletionだけを、完全に消費する。** `waitCompletion`/
  `pollCompletion`はそれぞれ、`io_uring_wait_cqe`/`_peek_cqe` +
  全フィールドの読み出し + `io_uring_cqe_seen`を、1回のアトミックなIdris
  呼び出しへまとめています。生の`struct io_uring_cqe *`と、呼び出し側が
  覚えておくべき別個の`cqeSeen`を公開するのではありません。多少の柔軟性
  (複数の未処理completionを、どれかをseen済みにする前に検分する、といった
  こと)と引き換えに、liburingの誤用として最も重大な結果を招くバグ——
  `io_uring_cqe_seen`を呼び忘れると、そのcompletion queueのスロットが
  二度と回収されず、リングが満杯になった時点で完全に詰まってしまう——を
  このパッケージ自身のAPIから構造的に不可能にしています。
- **バッファは常にバイト0から始まる。** `prepRead`/`prepWrite`/`prepSend`/
  `prepRecv`はどれも、素の`Data.Buffer`を取り、別途バイトオフセットの引数は
  取りません(`libs/rc2base`自身の`Network.RC2.sendBuf`/`recvBuf`とは違い
  ます——あちらは自前のシムが行う`data + off`のポインタ演算により、
  オフセットに対応しています)——これは先送りしているだけで、原理的な
  制約ではありません。将来もし大きなアキュムレータ用バッファの途中へ
  読み書きする必要が出てきたら、同じ要領でオフセット引数を追加すれば
  よいだけです。
- **ソケットの作成/bind/listenは同期のまま。** 上流の`Network.Socket`を
  経由し(ここでは再実装していません)、`prepAccept`/`prepConnect`/
  `prepSend`/`prepRecv`は、io_uringが実際に高速化する定常状態の、
  コネクション単位の操作だけをカバーしています。`Socket`自身の
  `.descriptor : Int`が、ここにあるすべての`prep*`関数が`fd`として
  期待しているものです。

## スコープ(意図的に先送りしている範囲)

- **Fixed files/buffers**(`IORING_SETUP_SQPOLL`、
  `io_uring_register_files`/`_buffers`、`IOSQE_FIXED_FILE`)——登録処理が
  重く、io_uring自身のAPIの中でも最もスループットの高い部分です。本来なら
  それ自体で本格的な設計作業(バッファ/ファイルスロットのライフタイム管理)
  が必要で、ここでは試みていません。
- **マルチショット操作**(`IORING_ACCEPT_MULTISHOT`、マルチショットの
  recv/poll)——1つのSQEが時間をかけて複数のCQEを生成するという形は、
  上記のこのパッケージ自身の「`waitCompletion`1回==リクエスト1件を完全に
  消費」という設計判断に、考え直さない限り収まりません。
- **Linked SQE**(`IOSQE_IO_LINK`——複数の操作を連結し、カーネルが前の
  操作の成功後にのみ次を開始する仕組み)——ここにある`prep*`関数はそれぞれ
  独立しており、連結用のフラグは公開していません。
- **Poll操作**(`io_uring_prep_poll_add`——io_uringを`epoll`の代わりに
  使う用途)——このプロジェクト自身のイベントループの必要は既に
  `System.Net.Epoll`がカバーしており(`Network.HTTP.Server`)、ここでは
  重複させていません。
- **`IORING_SETUP_SQPOLL`/その他の高度なセットアップフラグ**——`init`
  自身の`queueDepth`だけが公開されているノブです。既定を超える
  `io_uring_setup`フラグは、今回の最初の実装ではスコープ外です。

## 検証

`tests/verify.sh`: `libs/notcurses`(実際の端末が必要で、ほとんど自動化
できません)とは違い、このパッケージがカバーする操作はすべて完全にヘッドレス
です——実際の一時ファイルに対するファイルI/O、実際のループバックTCPでの
accept/connect/send/recvの往復、どちらも実際の`io_uring_submit`/
`waitCompletion`の往復を通じて最初から最後まで駆動しており、モックは
一切使っていません。`tests/`自身の`TestNop.idr`/`TestFile.idr`/
`TestSocket.idr`を参照してください。
