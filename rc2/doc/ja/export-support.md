# `%export`のサポート (`Compiler.RC2.RC2.validateExport`、`Compiler.RC2.Emit.Foreign.emitExportWrapper`)

(原文: `doc/export-support.md`。内容が乖離した場合は原文を正とする。)

Idris2の`%export "lang:exportedCName"`プラグマは、`%foreign`と同じ形式で関数に付ける。ただし向きは逆であり、外部の関数を束縛するのではなく、Idrisの関数を外部から呼べるようにする。rc2は従来このプラグマを何も処理していなかった。`compileExpr`が`getCompileData`に`exports=[]`を渡していたため、`CompileData.exported`が常に空になり、プラグマは警告もなく無視されていた。

上流のバックエンドも、`%export`に対して実際のC ABIのマーシャリングは行っていない。RefCはプラグマを完全に無視する。JSバックエンドは名前のmanglingを戻すだけで、中身はJSのクロージャのままであり、ネイティブの呼び出し境界にはなっていない。したがってrc2は、`%export`した関数に対して本物のネイティブC ABIのエントリポイントを生成する最初のバックエンドである。

## 設計: 変換ではなく、ラッパーの追加

`%export`した関数自身の、常にBoxedなコンパイル済みエントリポイント (`Main_add`など) には**一切手を加えない**。`Compiler.RC2.Emit.Foreign`の`emitExportWrapper`は、ユーザーが指定した名前で、ネイティブなCのパラメータ型と戻り値型を持つC関数を1つ追加で生成する。この関数は、次の順に処理する。

1. 各ネイティブ引数をボックス化する。
2. 元のエントリポイントを呼ぶ。
3. 結果をトランポリンで評価する。
4. 評価結果をネイティブなCの値に戻す。

`%foreign`側のFFIワーカー合成 (`Compiler.RC2.DualABI`のStage 3c) も、すでにBoxedとネイティブの境界を同じように扱っている。違いは向きだけで、`%export`ではネイティブ側からBoxed側を呼ぶのに対し、`%foreign`ではBoxed側からネイティブ側を呼ぶ。

認識する`%export`のタグは`"RC2:..."`、`"RefC:..."`、`"C:..."`である。これは`%foreign`が複数バックエンド向けのタグに使っているのと同じ`getCompileDataWith`のフィルタ一覧である。そのため、他のバックエンド向けに、あるいはバックエンドを限定せずに書かれた`%export "RefC:..."`や`%export "C:..."`の宣言も、rc2でそのまま動く。

## 実例: エクスポートした関数のコンパイルと呼び出し

このリポジトリのトップレベルの`README.md` (「Building and running」) に従って、セルフビルドしたツールチェーンが用意済みで、`rc2/build/exec/idris2-rc2`がすでに存在するものとする (`run-idris2-rc-cg`スキルも参照)。作業用ディレクトリに次の2つのファイルを置く。

`Add.idr`は次のとおりである。

```idris
module Main

%export "C:add_two_ints"
add : Int -> Int -> Int
add x y = x + y

%foreign "C:call_add_from_c,libc,Add.h"
prim__callAddFromC : PrimIO Int

main : IO ()
main = do
  printLn (add 2 3)          -- ordinary Idris call, wrapper untouched
  r <- primIO prim__callAddFromC
  printLn r                  -- proves the export is callable from plain C
```

`Add.c`には、対応する`Add.h`を添える。`Add.h`では次の2つを宣言する。

- `add_two_ints`: rc2が生成するラッパーである。`extern`で宣言すればよく、rc2のAPIは使わない。
- `call_add_from_c`: 上の`%foreign`が束縛する関数である。

```c
#include "Add.h"

int64_t call_add_from_c(void) {
    return add_two_ints(10, 32);
}
```

ビルドでは、まず`.c`ファイルをオブジェクトファイルにコンパイルする。そのうえで、環境変数`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`を使って`idris2-rc2`にオブジェクトファイルを教える。この2つは上流のIdris2と共通の環境変数で、`Compiler.RC2.CC`の`findCFlags`/`findLDFlags`が読む。`rc2/tests/verify.sh`も、`.c`ファイルを伴うスモークテストのたびに同じ手順を踏んでいる (`IDRIS2_LDFLAGS=...`の直前のコメントを参照)。

```sh
source env.sh   # from the repo root; puts install/bin/idris2-rc2's
                # runtime bits + the self-built toolchain on PATH

nix-shell -p gcc --run 'gcc -c Add.c -o Add.o'

IDRIS2_LDFLAGS="$PWD/Add.o" IDRIS2_CFLAGS="-I$PWD" \
  nix-shell -p gcc gmp pkg-config --run \
  '/path/to/idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 Add.idr -o add_demo'

./build/exec/add_demo
```

期待される出力は次のとおりである。

```
5
42
```

`5`はIdrisから通常どおり`add 2 3`を呼んだ結果である。`42`は`Add.c`から同じ`add_two_ints`ラッパーを呼んで得た`10 + 32`であり、C側はIdrisやrc2のAPIをまったく使っていない。なお`idris2-rc2`は、上流の`idris2`と同じく、リンクした実行ファイルを`./build/exec/<name>`に置く。`-o`で指定した名前のファイルがカレントディレクトリに直接できるわけではない。

### 変種: 外部のCが`main`を持つ場合 (`--directive nomain`)

実際に`%export`を使う側は、たいていこの形を望む。`%foreign`を経由する往復をやめ、補助の`.c`ファイルに自前の`main()`を持たせる。そのためには`--directive nomain`が必要である (後述「ライブラリとしてのリンク」を参照)。このディレクティブがないと、rc2が生成する`main()`と自前の`main()`がリンク時に衝突する。

`AddLib.idr`の`%export`は上の`Add.idr`と同じである。このIdris側の`main`が実行されることはない。

```idris
module Main

%export "C:add_two_ints"
add : Int -> Int -> Int
add x y = x + y

main : IO ()
main = putStrLn "this Idris main should never run"
```

`driver.c`は本物の`main`を持ち、エクスポートされた関数を直接呼ぶ。

```c
#include <stdint.h>
#include <stdio.h>

extern int64_t add_two_ints(int64_t, int64_t);

int main(void) {
    printf("%lld\n", (long long)add_two_ints(10, 32));
    return 0;
}
```

```sh
nix-shell -p gcc --run 'gcc -c driver.c -o driver.o'

IDRIS2_LDFLAGS="$PWD/driver.o" \
  nix-shell -p gcc gmp pkg-config --run \
  '/path/to/idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 --directive nomain AddLib.idr -o addlib_demo'

./build/exec/addlib_demo   # prints 42 -- driver.c's own main ran, not Idris's
```

## 対応範囲: スカラ、ポインタ、構造体、Integer、String

`Compiler.RC2.RC2.exportNfToCFType`が認識する型は次のとおりである。

- 当初からあるスカラ型 (`Int`、`Int8`/`Int16`/`Int32`/`Int64`、`Bits8`/`Bits16`/`Bits32`/`Bits64`、`Double`、`Char`)
- `Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr`
- `Integer`、`String`
- `Struct "name" [...]`形の任意の型。型コンストラクタの名前だけで照合し、名前空間は見ない。上流の`Compiler.CompileExpr`が使う`getNArgs`と同じ前例に従っている。
- 上記のいずれか (または`IO ()`) を包む`IO`/`PrimIO.IORes`

実際に位置ごとの検査を行うのは`Compiler.RC2.RC2.isExportableCFType`であり、`validateExport`がこれを呼ぶ。この関数は、従来のスカラ型に加えて`CFPtr`/`CFGCPtr`/`CFInteger`/`CFString`/`CFStruct`を明示的に受け入れる。これらにはそれぞれ、`Emit.Util`の`packCFType`/`extractValue`に本物のマーシャリング経路がある。複数のコード生成段階がRepの選択に共用している、スカラ専用で範囲の狭い`cfTypeNative`述語とは無関係である。

次のものは、いずれも意図的に対象外としている。

- `Buffer`
- `List`、`Maybe`、アプリケーション独自の`data`型など、そのほかのユーザー定義ADT
- 関数やクロージャの引数または戻り値

`%foreign`の語彙 (上流の`Compiler.CompileExpr.nfToCFType`/`getCFTypes`) は`CFFun`/`CFUser`/`CFBuffer`/`CFForeignObj`も受け入れるが、`%export`の対応範囲はそれより狭い。そのため、この対応範囲の検査には上流の関数を流用していない。後述の「実装していない2つの項目」も参照。

対応範囲外の宣言は、コンパイル時にただちに失敗する。エラーメッセージは、原因となった引数の位置または戻り値の型を明示するので、リンカの謎めいたエラーに悩まされることはない。次に示すエラーは、現在の`exportSupportedTypesDesc`/`validateExport`のソースから再構成したものであり、今回の更新にあたって新しくコンパイルして確かめ直したわけではない。これに対し、スカラ専用だった時代のこの例は、当時それが唯一の対象外の形だったので、実際にコンパイルして確認してある。

```
Error: [rc2] %export declaration <name> (Main.bad)'s own argument(s) [0]
own type isn't a type %export supports -- %export supports scalar
(Int/Int8/Int16/Int32/Int64/Bits8/Bits16/Bits32/Bits64/Double/Char), Ptr,
GCPtr, Integer, String, or struct (Struct) arguments
```

### Ptr/AnyPtrと構造体 (ポインタ渡し)

引数でも戻り値でも、`%foreign`が`CFPtr`にすでに使っているのと同じ、汎用の`packCFType`/`extractValue`の往復で処理する。`emitExportWrapper`に特別扱いを足す必要はなかった。`rc2/tests/Test59Export.idr`の`identityPtr : AnyPtr -> AnyPtr`は、Idrisが所有していない生のポインタを渡して、素のCから呼ぶ。補助のCコードは、まったく同じアドレスが返ってくることと、そのアドレスの指す先のメモリがまだ読めることを確かめる。後者は、ラッパーが戻り値を返したあとに行うdropで解放されていないことを意味する。素の`CFPtr`にはファイナライザがなく、dropが呼び出すものがないためである。

`Struct "name" [...]`型のエクスポートも、別の仕組みではなく同じ仕組みで扱う。`Emit.Util`の`cTypeOfCFType`/`extractValue`/`packCFType`は、いずれも`CFStruct`のケースを`CFPtr`のケースとそのまま同じにしてある。

`%foreign`の構造体サポートから引き継ぐ注意点が1つある。構造体のCのtypedefは、同じ構造体名を使う`%foreign`宣言がプログラム中に実際に残っているときにだけ出力される (`Compiler.RC2.Emit`の`StructDefs`)。`%export`から構造体を参照するだけでは、typedefは残らない。`Test59Export.idr`がこの対処の実例である。`getXExport`/`scalePoint`の2つのエクスポートだけが、構造体として`"test_point"`構造体を必要とする。それでもこのファイルは、同じ構造体について宣言した`%foreign`の`prim__makePoint`/`prim__freePoint`の組を残し、`main`から参照している。これは`Compiler.RC2.DeadCode.pruneDeadDefs`がこの組を削除して、構造体のtypedefまでエクスポートの足元から消してしまうのを防ぐためだけである。

### GCPtr/GCAnyPtr: 引数の位置のみ

`GCPtr`/`GCAnyPtr`は**引数**としては受け入れるが、**戻り値**の型としてはコンパイル時に拒否する。`Test59Export.idr`では、Idrisが関知しない生のポインタを`packCFType CFGCPtr`の`idris2rc2_mkGCPointer(raw, NULL)`で包んでいる。ポインタはもともとIdrisが所有するものではないため、ファイナライザは付けない。戻り値で拒否するときのエラーは次のとおりである。

```
[rc2] %export declaration <name> (Main.f)'s own return type is a
GC-managed pointer (GCPtr/GCAnyPtr) -- returning one via %export isn't
supported: the wrapper's own drop-after-return step could invoke the
pointer's finalizer (if one is attached) before the C caller ever sees
the value
```

危険があるのは戻り値の位置に限られる。`emitExportWrapper`は、トランポリンで得た結果からネイティブのペイロードを読み出した直後に、その結果を無条件で`idris2rc2_drop`する (後述の「メモリ」を参照)。`GCPtr`にはファイナライザが付いていることがあり、参照カウントが0になるとそれが実行される。つまり、*返す*ポインタのファイナライザが、Cの呼び出し側が値を見る前に走るおそれがあり、use-after-freeになる。引数の位置の`GCPtr`にはこの危険がない。ラッパーがdropするのは自分の戻り値だけで、引数はdropしないためである。

### Integer (GMP): 引数と戻り値の両方向

`Integer`は両方向ともGMPの`mpz_t`を介して往復する。ただし、どちらの向きも、汎用の`packCFType`/`extractValue`の経路をそのまま使うわけではない。

- **引数**: 渡されてくる値は生の`mpz_t`である。`packCFType CFInteger`の恒等的な素通しは、値がすでに`IDRIS2RC2_Integer*`であると仮定している。この仮定が成り立つのは、ほかのすべての場面で、先行する生成コードがすでに`IDRIS2RC2_Integer`を作っているためである。`%export`の引数ではその前提が成り立たない。そこで新しいヘルパー`idris2rc2_mkIntegerFromMpz` (`rc2/support/rc2/memory.c`/`.h`) が、まず値をコピーして取り込む。

  ```c
  IDRIS2RC2_Integer *idris2rc2_mkIntegerFromMpz(mpz_t src) {
    IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
    mpz_set(v->v, src);
    return v;
  }
  ```

  `emitExportWrapper`の`argPack`は、`CFInteger`だけを特別扱いして、汎用の`packCFType`の代わりにこのヘルパーを呼ぶ。

- **戻り値**: GMPの`mpz_t`には、Cで値渡しに返す形がそもそもない。そのため、`Integer`を返すエクスポートでは、ラッパーのシグネチャの先頭に`mpz_t out`パラメータを追加し、Cの戻り値の型を`void`にする。これは、`%foreign`側で`Integer`を返す場合の出力パラメータの規約 (`Test118FFI/FFIInteger.idr`を参照) と同じであり、`emitGenericForeignWrapper`がすでに採っている。本体は`mpz_init(out); mpz_set(out, <extracted value>);`に続けて、トランポリンで得たBoxedの結果の明示的な`idris2rc2_drop`と、値を持たない`return;`である。

以下は`rc2/tests/Test59Export/`から取り出した例である。このテストは、64ビットの`Int`の範囲を大きく超える値で両方向を検証している。

`Test59Export.idr`の該当部分は次のとおりである。

```idris
%export "C:idris2rc2_test63_add"
addInteger : Integer -> Integer -> Integer
addInteger x y = x + y
```

`Test59Export.h`では、GMPの規約に合わせて`out`が*最初*のパラメータになる。

```c
extern void idris2rc2_test63_add(mpz_t out, mpz_t x, mpz_t y);
```

補助のCコードは、GMPとしては正しいが`Int64`の範囲を超える値で呼ぶ。

```c
mpz_t a, b, out;
mpz_init_set_str(a, "123456789012345678901234567890", 10);
mpz_init_set_str(b, "1", 10);
mpz_init(out);
idris2rc2_test63_add(out, a, b);
/* out == 123456789012345678901234567891 */
```

ビルド手順は上の「実例」と同じである。補助の`.c`を`.o`にコンパイルし、`IDRIS2_LDFLAGS`で指定する。rc2自体が必要とする`nix-shell -p gcc gmp pkg-config`の行には、すでに`gmp`が入っている。この`CFInteger`の節が`rc2/tests/Test59Export/Test59Export.expected`に追加する行は次のとおりである。

```
42
1
```

`42`は、Idrisから通常どおり`addInteger 40 2`を呼んだ結果である。`1`は、補助のCコードによるGMPの値の検査が成功したことを表す。

### String: 引数と戻り値で異なる所有権の規約

`isExportableCFType`は`CFString`を両方の位置で受け入れる。ただし、専用のラッパー処理が必要だったのは**戻り値**の向きだけである。引数の`String`は、ほかのすべての`%foreign`やネイティブ入力の呼び出し箇所が使う、汎用の`packCFType CFString`を使う。これは`idris2rc2_mkString(varName)`を呼んで、渡された`const char *`を新しく所有する`IDRIS2RC2_String`にコピーする。したがって、このコピー以外に、所有権について特記すべきことはない。

`Test59Export`はこの点を直接確認している。補助のCドライバは、Idrisやrc2が管理していないメモリである素の文字列リテラルを渡す。呼び出し後にその文字列が変更されていないことを確かめて、rc2が呼び出し側のバッファを別名で参照したり、所有権を取ったりしないことを示している。一方、所有権の取り決めが実際に問題になるのは戻り値の向きであり、こちらは以降で扱う。

どちらの向きも素の`char *`を介して境界を越える。しかも`idris2rc2_mkString`は`strlen`に基づく。そのため、C側から渡す引数の文字列も、戻り値側 (後述) のIdrisの`String`の結果も、NULバイトを含んでいればどちらの向きでも最初のNULで切れる。これは、このプロジェクトのほかの`char *`型のFFI境界と同じ扱いである (`rc2/doc/fastpack-fix.md`、トップレベルの`README.md`の「Deliberate differences from upstream RefC」)。rc2でコンパイルした2つの関数のあいだで受け渡す`IDRIS2RC2_String`には、この制限がない。制限を受けるのは、実際に素のCとの境界を越える値だけである。`%export`と`%foreign`の`CFString`は、すべてこれに当たる。

**戻り値**には、実際の修正が必要だった。`extractValue`の`CFString`のケースは、Boxedの値が持つmalloc済みバッファ (`((IDRIS2RC2_String*)v)->str`) をコピーせずに別名で参照する。そのポインタを返してから、そのポインタの元になったBoxedの値をdropしてしまうと (ラッパーが戻り値を返したあとに必ず行う後始末がそれである)、Cの呼び出し側にダングリングポインタを渡すことになる。そのため`emitExportWrapper`は、`CFString`の戻り値を次のように処理する。

```c
IDRIS2RC2_Value *r = idris2rc2_trampoline(<call>);
const char *raw = ((IDRIS2RC2_String*)r)->str;
size_t len = strlen(raw) + 1;
char *result = malloc(len);
memcpy(result, raw, len);
idris2rc2_drop(r);
return result;
```

ここで`r`自身の`len`フィールド (`rc2/doc/constructor-layout.md`) を読まずに`strlen`を使うので、前述のNULによる切り詰めが起こる。これは意図的である。ラッパーの戻り値の型は素の`char *`であり、素のCの呼び出し側が長さを読み取るための出力パラメータがない。`char *`だけで長さを保つ規約は存在しないので、代わりに頼れるものもない。

このケースでラッパーが返すCの型は、素の`char *`である。`%foreign`の「借用した不変のビュー」という規約のために用意された、`cTypeOfCFType CFString`の通常の対応である`const char *`は**使わない**。バッファは独立した、呼び出し側が所有する確保領域になっており、呼び出し側が`free()`するはずのポインタに`const`を付けると、かえって誤解を招くためである。

**所有権の規約**: 返された`char *`は、独立した素の`malloc`領域である。Cの呼び出し側が完全に所有し、使い終わったら自分で`free()` **しなければならない**。このポインタを`idris2rc2_*`関数に渡してはならない。`IDRIS2RC2_String`ではなく、その型のヘッダも持たないためである。

`rc2/tests/Test59Export/`から取り出した例を示す。

```idris
%export "C:idris2rc2_test64_greet"
greetStr : Int -> String
greetStr n = "hello " ++ show n
```

```c
// Test59Export.h
extern char *idris2rc2_test64_greet(int64_t n);
```

```c
// companion C
char *s = idris2rc2_test64_greet(9);
int64_t ok = (strcmp(s, "hello 9") == 0);
free(s);   // caller's responsibility -- see ownership contract above
```

この`CFString`の戻り値の節が`Test59Export.expected`に追加する行は次のとおりである。

```
hello 7
1
```

`hello 7`は、Idrisから`putStrLn`を介して通常どおり`greetStr 7`を呼んだ結果である。`1`は、補助のCコードによる`strcmp`と`free`の検査が成功したことを表す。

### Buffer: 引き続き対象外

`Buffer`は、どちらの向きでも未対応である。`String`の戻り値の規約が明示的に解決した所有権の問題を、`Buffer`も共有している。誰が確保し、誰が、どのアロケータで解放するかという問題である。さらに`Buffer`には`String`にない問題もある。NUL終端の`char *`と違って、`Buffer`の大きさは値自身からは分からない。そのため`%export`の境界を越えるには、長さをCの呼び出し側に伝える規約が別に必要になる。出力パラメータ、固定の最大長、長さを先頭に付ける方式などが考えられるが、まだ設計していない。将来、改めて検討する可能性がある。

## `IO`/`PrimIO`の戻り値の特別扱いとWorld引数

`IO`と`IORes`はどちらも本物の`data`型である (`libs/prelude/PrimIO.idr`)。したがって、`T1 -> T2 -> IO R`型のエクスポートを正規化した型は、`R`を包む通常の`NTCon`になる。`%foreign`が`PrimIO`/`CFIORes`の戻り値を剥がすのと同じ要領で、これを`Compiler.RC2.DualABI.peelIORes`で剥がす。

`IO ()`を返すエクスポートに対応する`CFUnit`は、特別なケースとして受け入れる。戻り値の側にはネイティブのマーシャリングが一切ない。ラッパーのCの戻り値の型は`void`で、トランポリンで得た結果は読まずに捨てる。`Compiler.RC2.Emit`が生成する`main()`も、プログラム全体の最終結果を同じように捨てている。

実装中に実際に確かめたことがある。ソースを読んだだけの想定ではない。`main`のエントリポイント (`__mainExpression`、アリティ0) では、`%World`トークンがプログラム全体の最上位ですでに1回適用されている。これはラムダリフティングより前に行われる。これに対し、`IO`/`IORes`を返す*通常の*関数は、末尾の`%World`パラメータを、消去されない実際のパラメータ (数量は0ではなく1) としてコンパイル後 (`Lifted`) のアリティまで持ち続ける。そのため、スカラ引数の個数をコンパイル済み定義のアリティと素朴に比較すると、`IO`を返すエクスポートのすべてで、誤った不一致が報告されてしまう。`Compiler.RC2.RC2.validateExport`は、エクスポートの戻り値の型が`CFIORes _`のとき、この余分な1つ分を計算に入れる。`emitExportWrapper`は、呼び出すときにBoxedの`NULL`定数をこの引数として渡す。`Compiler.RC2.Emit.Util`の`packCFType`/`extractValue`も、`CFWorld`について、ほかのあらゆる場所で同じプレースホルダを使っている。

## メモリ: `Unit`以外の戻り値の後に必ず行う明示的なdrop

rc2がコンパイルして出力する通常のコードでは、Repによって決まる経路のすべてで、所有権とdropの管理が静的に一度だけ決まる。決めるのは`Compiler.RC2.RC`の`annotate`パスであり、その結果は明示的な`RDrop`/`RFree`ノードとして木に埋め込まれる。`emitExportWrapper`は、このパイプラインの外にある、手書きの生のCテキストである。そのため、ここでの正しさはラッパー自身が責任を持つ。`extractValue`がトランポリンで得たBoxedの結果からネイティブのペイロードを読み出したあとで、ラッパーはその結果を明示的に`idris2rc2_drop`する。

これは念のための防御ではなく、実際に必要な修正である。`main`のフッタは、最終結果をdropしなくても済む。直後にプロセスが終了するためである。これに対し、このラッパーは外部のCから何度でも呼ばれうる。ヒープを確保して返す戻り値 (`CFDouble`、または`immediate-ints.md`の即値の範囲を外れた`CFInt`/`CFInt64`/`CFUnsigned64`の値) は、dropしなければ、そうした呼び出しのたびにリークする。

dropは無条件に行う。`CFChar`/`CFInt8`/.../`CFUnsigned32`の値は実際のヒープ確保ではないが、これらにも行う。`idris2rc2_drop`は、常にアンボックスな値や`NULL`に対しては、安全に何もしないためである。この「何もしない」動作は、実装上たまたまそうなっているのではなく、ランタイムが文書化して保証している (理由は`Compiler.RC2.Types.alwaysUnboxed`のドキュメントコメントを参照)。

`CFInteger`と`CFString`の戻り値は、この汎用の経路を通らない。それぞれ専用の処理を、前掲の「対応範囲」の各節で説明した。ただし、どちらも、ラッパーが呼び出し側へ戻る前に、トランポリンで得たBoxedの結果を明示的に`idris2rc2_drop`して終わる。リークを防ぐという理由は同じである。

## 実装していない2つの項目 (v1)

- **Cヘッダを生成しない。** ラッパーのプロトタイプは、それを呼ぶCコードが手で`extern`宣言する必要がある (パターンは`rc2/tests/Test59Export.h`を参照)。rc2は、生成した`.c`と並べて`.h`を出力することをまだしていない。
- **対応範囲は、引き続き限られている。** 「対応範囲」で述べたとおり、スカラ、`Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr` (引数のみ)、`Integer`、`String`、ポインタ渡しの構造体には対応した。`Buffer`、そのほかのユーザー定義ADT (`List`、`Maybe`、アプリケーション独自の`data`型)、関数やクロージャの引数と戻り値には、まだ対応していない。これらのうちの少なくとも一部は、`%foreign`が逆方向ですでにサポートしている。

## ライブラリとしてのリンク (`--directive nomain`)

以前は、生成した`.c`のすべてが、末尾に自前のCの`main()`を無条件に持っていた (`Compiler.RC2.Emit`の`footer`)。この`main()`は`__mainExpression_0()`を呼び、その結果をトランポリンで評価する。通常の独立した実行ファイルならこれで問題ない。しかし、自前の`main()`を定義する補助の`.c`ファイルがあると、シンボルの重複によるリンクエラーになってしまう。`%export`を使う側が自然に望むのは、まさにその形である。`main`を持つ手書きのCドライバが、エクスポートされたシンボルを直接呼ぶ。

`--directive nomain`と`%cg rc2 nomain`は、この問題を解決する。`footer`を完全に省略するので、生成した`.c`は自前の`main()`を持たず、外部の`main()`と並べて問題なくリンクできる。動作確認済みの完全な手順は、上の「実例」の「変種: 外部のCが`main`を持つ場合」を参照。

この生成された`main()`は、ランタイムのライフサイクルフックの呼び出し場所でもある (`doc/runtime-lifecycle.md`)。`nomain`を使うときは、手書きのドライバがその役割を引き受ける。最初のエクスポートの呼び出しの前に`idris2rc2_rtInit()`を1回呼び (内部で`setlocale(LC_ALL, "")`を実行する)、プロセスを終了する前に`idris2rc2_rtFinish()` (`fflush`) を呼ぶ。どちらも`runtime.h`で宣言されており、`idris2rc2_runtime.h`の包括ヘッダ経由で参照できる。`rtInit`を呼ばなくてもクラッシュはしない。プログラムは`"C"`ロケールのままになるだけで、これはフックが導入される前の動作である。

## DeadCodeでの生存

`%export`した名前は、プログラムのほかの部分から呼ばれているかどうかにかかわらず、`Compiler.RC2.DeadCode.pruneDeadDefs`が決して削除してはならないルートである。`Compiler.RC2.RC2.compileExpr`の`roots`リストには、`exported cdata`の名前がすでに含まれていた。この機能が実際にリストへ値を入れる前から、そうなっていたのは、この目的のためである (それまでは、実際には常に`[]`だった)。

この機能を実際に配線したときに、実バグが1件見つかったので修正した。`Compiler.Common.getExports`は、各エクスポート名を`toFullNames`ではなく`resolved`で解決する。そのため`exported cdata`の`Name`は`Resolved` (コンテキストのインデックス) 形式になる。一方、`pruneDeadDefs`が走査する`RCDef`パイプラインのエントリは、すべて完全名をキーとしている。`Name`の等価性は構造的に比較されるので、`Resolved`形式のルートは、どのエントリとも決して一致しない。現在の`roots`は、自前で名前を導出し直して誤った結果を得る代わりに、`validateExport`が`getFullName`で解決した名前を再利用している。

3つ目のエクスポート (`Test59Export.idr`の`unused`) で確認した。`main`はこれを一度も呼ばないが、そのラッパーと元の常にBoxedなエントリポイント (`idris2rc2_test_unused`/`Main_unused`) の両方が、生成したCにちゃんと現れる。

## 参照テスト

`rc2/tests/Test59Export/` (`.idr`と、その補助の`.c`/`.h`) は、1つに統合したテストである。7つの節で、`%export`が扱う`CFType`の形をすべて網羅している。各節は、通常のIdrisのコードからも、手書きの素のCからも呼ばれる。後者は、エクスポートされたシンボルを直接呼ぶC関数を`%foreign`で束縛して行い、Idrisやrc2のAPIは使わない。

このテストは`verify.sh`の`NO_REFC_DIFF_TESTS`に入っている。本物のRefCは`%export`のマーシャリングをまったく持たないので、`--cg refc`で比較用にビルドしても、補助の`.c`ファイルの`extern`宣言がリンクできずに失敗するだけだからである。また`LEAK_SENSITIVE_TESTS`にも入っている。`CFInteger`/`CFString`の節にある、コピーして取り込み、コピーして返す所有権の経路を検査するためである。

- §1 (旧`Test59ExportScalar`): 2つのスカラ関数 (`Int`/`Double`) と、そのほかに使われない3つ目のエクスポートを用意する。3つ目は、上述のDeadCodeでの生存の保証を確かめる。
- §2 (旧`Test60ExportPtr`): `CFPtr`を両方向で扱い、アドレスの同一性と生存を検査する。
- §3 (旧`Test61ExportStruct`): ポインタ渡しの`CFStruct`。「対応範囲」で述べた、構造体のtypedefの生存に関する注意点も扱う。
- §4 (旧`Test62ExportGCPtr`): `CFGCPtr`を引数のみで扱う。
- §5 (旧`Test63ExportInteger`): `CFInteger`を両方向で、GMPの範囲の値を使って扱う。
- §6 (旧`Test64ExportString`): `CFString`の戻り値と、呼び出し側が`free()`するという所有権の規約。
- §7 (旧`Test65ExportStringArg`): `CFString`の引数。呼び出し側のバッファがコピーされ、rc2が別名で参照することも解放することもないことを確かめる。
