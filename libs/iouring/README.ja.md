# iouring

*[English](README.md)*

`System.IO.Uring` -- LinuxのAPI「`io_uring`」に対する非同期I/O向けIdris2バインディング。
[liburing](https://github.com/axboe/liburing)経由で実装しています。ほぼ全体が
`liburing.h`自身の`static inline`APIへの直接`%foreign`バインディングです(シムは
不要——rc2のコード生成器は`%foreign`宣言のヘッダを、呼び出し側自身が生成する`.c`
ファイルへ直接`#include`します)。残った小さなシム(`support/c/iouring_util.c`)は、
リングのライフサイクル・`sockaddr`の構築・`%foreign`では直接表現できない一部の
out引数シグネチャだけを扱っています。設計の全容と、このパッケージが意図的にまだ
カバーしていない範囲(fixed files/buffers、マルチショットのrecv/poll、linked SQE、
`SQPOLL`——マルチショット操作としては、今のところ`prepMultishotAccept`だけに
対応しています)については`doc/iouring.ja.md`(英語版は`doc/iouring.md`)を
参照してください。

## ビルド・テスト

ビルドには **`liburing`、`pkg-config`、Cコンパイラ** が`PATH`上に必要です
(例: `nix-shell -p liburing pkg-config gcc gnumake`)。加えて`io_uring`に対応した
十分新しいカーネル(5.1以降——このパッケージがカバーする操作は実際にはそれより
かなり古いカーネルでも動作します)が要ります。

デフォルトのChezバックエンドで、型チェックのみ:
```sh
idris2 --build iouring.ipkg
```

`idris2-rc-cg`自身の`rc2`バックエンド向け(`libs/iouring`は`idris2-rc-cg`内に
あるので、リポジトリをまたいだ`env.sh`の読み込みは不要です)。rc2自身が使うのと
*同じ*`install/`プレフィックスへインストールします——idris2は既定で自分自身の
インストールプレフィックスを検索するので、パッケージパスを別途設定する必要も、
`IDRIS2_PREFIX`をexportする必要もありません——`env.sh`が用意する自前ビルド版
`idris2`は、既にこのリポジトリ自身の`install/`をデフォルトのプレフィックスとして
知っています(`idris2 --prefix`で確認できます)。`-p iouring`だけでビルド対象に
できます——`Compiler.RC2.CC`自身の`depPkgLibDirs`が、依存先パッケージそれぞれの
`lib/`向けに`-I`/`-L`を自動で追加してくれるので、`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`
は不要です:
```sh
cd idris2-rc-cg            # リポジトリのルート
source ./env.sh
(cd libs/iouring && idris2 --install iouring.ipkg)

nix-shell -p liburing gcc gmp pkg-config --run '
  ./rc2/build/exec/idris2-rc2 --cg rc2 -p iouring -o MyProgram libs/iouring/tests/TestNop.idr
  ./build/exec/MyProgram
'
```
`LD_LIBRARY_PATH`のexportは一切不要です。`liburing`自体は実体の共有ライブラリ
としてリンクされます(`-luring`——これを名指しするすべての`%foreign`宣言によっ
て自動的にリンクへ追加されます。このパッケージ自身の静的アーカイブ
`libidris2rc2iouring.a`が持つのは、実際にコンパイルされたシム関数だけです)。
そのため`notcurses`/`text-re2`と違い、`nix-shell -p liburing`の中でビルド
(・実行)する限り、独自の`LD_LIBRARY_PATH`エントリを追加する必要はありません
(nix shell自身の環境が、コンパイル時・実行時どちらでも`liburing.so`を見つけ
られるようにしています)。`support/rc2`にはそもそも`.so`自体がなく、どのみち
追加する意味はありません。

`tests/verify.sh`は自動化された一式のテストを実行します: `nop`のsubmit/complete
往復、実際の一時ファイルに対する`openat`+`write`+`fsync`+`close`+`read`での
読み戻し、そして実際のループバックTCPでの`accept`/`connect`/`send`/`recv`の
往復——すべてヘッドレスで、TTYも`127.0.0.1`以外へのネットワークアクセスも
必要ありません。

## ネイティブライブラリのインストール先

`rc2base`/`text-re2`/`notcurses`と同じ規約です——`libs/rc2base/README.md`の
「Native library install location」節を参照してください。`idris2 --install`は
`.ttc`/`.ttm`/`.ipkg`しかコピーしません。このパッケージの`postinstall`フック
(`make -C support/c install`)が、`libidris2rc2iouring.a`と`iouring_util.h`を
`<IDRIS2_PREFIX>/idris2-<ver>/iouring-0.1.0/lib/`へ置く役目を担っています。
rc2自身の`Compiler.RC2.CC.depPkgLibDirs`が、依存先パッケージそれぞれについて
この`lib/`を自動的に見つけます(`-p iouring`、または`.ipkg`の`depends`エントリが
あれば十分です)——*これ*(このヘッダ)についてはIDRIS2_CFLAGS/IDRIS2_LDFLAGSを
手で設定する必要はありません。`liburing.h`自体は、`nix-shell -p liburing`が
提供するヘッダ全般と同じ方法で、シェル自身の環境経由で見つかります。

## API

```idris2
import System.IO.Uring

main : IO ()
main = do
  Just ring <- init 8
    | Nothing => putStrLn "io_uring_queue_init failed"
  Just sqe <- getSqe ring
    | Nothing => putStrLn "submission queue full"
  prepNop sqe
  setUserData sqe 42
  _ <- submit ring
  Just completion <- waitCompletion ring
    | Nothing => putStrLn "wait failed"
  printLn (completion.userData, completion.res)
  exit ring
```

API全体(`prepRead`/`prepWrite`/`prepOpenat`/`prepClose`/`prepFsync`/`prepAccept`/
`prepConnect`/`prepSend`/`prepRecv`)については`System.IO.Uring`自身のドキュメント
コメントを、実際に動く完全な例については`tests/`を参照してください。
