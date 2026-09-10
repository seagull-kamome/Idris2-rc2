# `%export` サポート(`Compiler.RC2.RC2.validateExport`、`Compiler.RC2.Emit.Foreign.emitExportWrapper`)

(原文: `doc/export-support.md`。内容が乖離した場合は原文を正とする。)

Idris2 の `%export "lang:exportedCName"` プラグマ(`%foreign` と同じ
付加構文だが、逆方向 -- 外部のものを束縛するのではなく Idris
関数を外部から呼べるようにする)は、以前 rc2 で何もしなかった:
`compileExpr` が `getCompileData` に `exports=[]` を渡していたので
`CompileData.exported` は常に空で、プラグマは静かに無視された。
上流のどのバックエンドもそれに対して本物の C-ABI marshalling を
しない -- RefC は完全に無視し、JS バックエンドは名前の unmangling
だけをする(その下はまだ JS クロージャで、ネイティブ呼び出し境界
ではない)。これにより rc2 は `%export` された関数に対して本物の
ネイティブ C-ABI エントリポイントを生成する最初のバックエンドに
なる。

## 設計: 変換ではなく追加ラッパ

`%export` された関数自身の常にボックス化されたコンパイル済み
エントリポイント(`Main_add` など)は**決して触れられない**。
`Compiler.RC2.Emit.Foreign` の `emitExportWrapper` は、ユーザー
指定の名前で、ネイティブ C のパラメータ/戻り値型を持つ 1 つの
追加 C 関数を生成する: 各ネイティブ引数をボックス化し、元の
エントリポイントを呼び、結果をトランポリンし、ネイティブ C 値へ
逆ボックス化する。これは `%foreign` 自身の FFI ワーカー合成
(`Compiler.RC2.DualABI` の Stage 3c)が既に扱うボックス化/
ネイティブ境界を反映するが、逆方向(ネイティブ入力がボックス化を
呼ぶ、ボックス化入力がネイティブを呼ぶのではなく)である。

認識される `%export` タグ: `"RC2:..."`、`"RefC:..."`、`"C:..."`
(`%foreign` 自身のマルチバックエンドタグ規約が使う同じ
`getCompileDataWith` フィルタリスト)-- なので、別のバックエンド
向けに書かれた、あるいは汎用に書かれた既存の `%export "RefC:..."`
や `%export "C:..."` 宣言も、rc2 を通して無変更で動く。

## 実例: エクスポートされた関数のコンパイルと呼び出し

このリポジトリ自身のトップレベル `README.md`
("Building and running")の自己ビルドツールチェーンが既にセット
アップされ、`rc2/build/exec/idris2-rc2` が既に存在すると仮定する
(`run-idris2-rc-cg` スキルも参照)。スクラッチディレクトリに
2 つのファイル:

`Add.idr`:

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

`Add.c`(+ 対応する `Add.h`。`add_two_ints` -- rc2 生成ラッパ、
`extern`、rc2 API は一切関与しない -- と、上記 `%foreign` が束縛
する `call_add_from_c` の両方を宣言する):

```c
#include "Add.h"

int64_t call_add_from_c(void) {
    return add_two_ints(10, 32);
}
```

ビルド: まず伴走 `.c` をオブジェクトファイルにコンパイルし、次に
`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` 経由で `idris2-rc2` にそれを指す
(`Compiler.RC2.CC` 自身の `findCFlags`/`findLDFlags` が読む同じ
上流 Idris2 の環境変数 -- これはまさに `rc2/tests/verify.sh` が
伴走 `.c` ファイルを持つすべてのスモークテストで行うこと、
`IDRIS2_LDFLAGS=...` の上のコメントを参照):

```sh
source env.sh   # from the repo root; puts install/bin/idris2-rc2's
                # runtime bits + the self-built toolchain on PATH

nix-shell -p gcc --run 'gcc -c Add.c -o Add.o'

IDRIS2_LDFLAGS="$PWD/Add.o" IDRIS2_CFLAGS="-I$PWD" \
  nix-shell -p gcc gmp pkg-config --run \
  '/path/to/idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 Add.idr -o add_demo'

./build/exec/add_demo
```

期待される出力:

```
5
42
```

(`5` = Idris から通常に呼ばれた `add 2 3`; `42` = C 側で
Idris/rc2 API を一切関与させずに `Add.c` から同じ `add_two_ints`
ラッパを呼んで計算した `10 + 32`。)`idris2-rc2` は上流 `idris2`
と同じく、リンクされた実行ファイルをカレントディレクトリの `-o`
名に直接ではなく `./build/exec/<name>` 以下に置くことに注意。

### バリアント: 外部 C が `main` を所有する(`--directive nomain`)

`%foreign` の往復を落とし、代わりに伴走 `.c` ファイルに自身の
`main()` を持たせる -- 本物の `%export` 消費側が通常望む形状。
これには `--directive nomain`(下記 "ライブラリとしてリンク" を
参照)が必要で、rc2 自身の生成 `main()` がリンク時にそれと衝突
しないようにする。

`AddLib.idr`(上記 `Add.idr` と同じ `%export`; 自身の Idris
`main` は決して到達されない):

```idris
module Main

%export "C:add_two_ints"
add : Int -> Int -> Int
add x y = x + y

main : IO ()
main = putStrLn "this Idris main should never run"
```

`driver.c`(本物の `main` を所有し、エクスポートを直接呼ぶ):

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

## スコープ: スカラー、ポインタ、構造体、Integer、String

`Compiler.RC2.RC2.exportNfToCFType` が認識するもの: 元のスカラー
集合(`Int`、`Int8`/`Int16`/`Int32`/`Int64`、
`Bits8`/`Bits16`/`Bits32`/`Bits64`、`Double`、`Char`)、加えて
`Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr`、`Integer`、`String`、そして
任意の `Struct "name" [...]`(素の型コンストラクタ名でマッチ、
名前空間を無視 -- 上流自身の `Compiler.CompileExpr` が使う同じ
`getNArgs` の先例)、そしてそれらのいずれか(または `IO ()`)を
包む `IO`/`PrimIO.IORes`。`Compiler.RC2.RC2.isExportableCFType` が
`validateExport` が検査する実際の位置ごとのゲートである: 以前と
同じスカラー集合の上に、`CFPtr`/`CFGCPtr`/`CFInteger`/`CFString`/
`CFStruct` を明示的に許容する(各々 `Emit.Util` の
`packCFType`/`extractValue` に本物の marshalling 経路を持つ。
いくつかの他のコード生成ステージが Rep 選択のために共有する、
より狭い純粋スカラーの `cfTypeNative` 述語とは無関係)。

`Buffer`、他の任意のユーザー定義 ADT(`List`、`Maybe`、または
アプリケーション自身の `data` 型)、関数/クロージャの引数/戻り値
は今もない -- 意図的にスコープ外で、`%foreign` 自身の語彙
(上流の `Compiler.CompileExpr.nfToCFType`/`getCFTypes`。それらは
`CFFun`/`CFUser`/`CFBuffer`/`CFForeignObj` も受け入れるので、
ここでは再利用しない)より今も狭い。下記
"実装されていない 2 つのスコープ項目" を参照。

このスコープ外の宣言は今もコンパイル時に即座に、責任を追える形で
失敗し、エラーに問題の引数位置や戻り値型が名指しされる -- 下流の
リンカの謎ではない。現在の
`exportSupportedTypesDesc`/`validateExport` ソースから再構成した
(この更新のために新規コンパイルに対して再検証していない --
これが唯一の非対応形状だった当時に経験的に検査されたスカラーのみ
時代の版とは異なる):

```
Error: [rc2] %export declaration <name> (Main.bad)'s own argument(s) [0]
own type isn't a type %export supports -- %export supports scalar
(Int/Int8/Int16/Int32/Int64/Bits8/Bits16/Bits32/Bits64/Double/Char), Ptr,
GCPtr, Integer, String, or struct (Struct) arguments
```

### Ptr/AnyPtr と構造体(ポインタ経由)

両方向、引数と戻り値。`%foreign` が既に `CFPtr` に使っているのと
まったく同じ汎用 `packCFType`/`extractValue` の往復を通す --
`emitExportWrapper` はどちらにも特別扱いを必要としなかった。
`rc2/tests/Test59Export.idr` の
`identityPtr : AnyPtr -> AnyPtr` は、生の非 Idris 所有ポインタで
素の C から呼ばれる; 伴走 C は、まったく同じアドレスが返ることと、
その背後のメモリがまだ読める(つまりラッパ自身の return 後 drop
ステップで解放されていない。素の `CFPtr` はそのステップが呼ぶ
ファイナライザを持たないので)ことの両方を検査する。

`Struct "name" [...]` 型のエクスポートは、別の機構ではなくこの
同じ機構を使う -- `Emit.Util` の
`cTypeOfCFType`/`extractValue`/`packCFType` はすべて `CFStruct`
ケースを `CFPtr` のものにそのままエイリアスする。`%foreign` 自身
の構造体サポートから 1 つの注意事項が引き継がれる: 構造体の C
typedef は、その同じ構造体名を使うライブの `%foreign` 宣言が
プログラムのどこかに存在するときだけ出力される
(`Compiler.RC2.Emit` の `StructDefs`)-- 構造体への `%export`
参照だけでは typedef を生かし続けるのに十分でない。
`Test59Export.idr` は実際上のパターンを示す: その
`getXExport`/`scalePoint` エクスポートが構造的に `"test_point"`
構造体を必要とする唯一のものだが、ファイルは `main` から参照
される `%foreign` 束縛の `prim__makePoint`/`prim__freePoint` の
ペア(その同じ構造体上に宣言)も保持する。純粋に
`Compiler.RC2.DeadCode.pruneDeadDefs` がそれら -- と一緒に
構造体 typedef -- をエクスポートの下から剥がさないようにするため
である。

### GCPtr/GCAnyPtr: 引数位置のみ

**引数**として受け入れられる(`Test59Export.idr` は
`packCFType CFGCPtr` 自身の `idris2rc2_mkGCPointer(raw, NULL)`
経由で生の Idris 非認識ポインタを包む -- ポインタがそもそも
Idris 所有でないので、ファイナライザは付かない)が、**戻り値**型
としてはコンパイル時に拒否される:

```
[rc2] %export declaration <name> (Main.f)'s own return type is a
GC-managed pointer (GCPtr/GCAnyPtr) -- returning one via %export isn't
supported: the wrapper's own drop-after-return step could invoke the
pointer's finalizer (if one is attached) before the C caller ever sees
the value
```

危険は戻り値位置に固有である: `emitExportWrapper` は、ネイティブ
ペイロードを読み出した直後に自身のトランポリンされた結果を無条件
で `idris2rc2_drop` する(下記 "メモリ" を参照)、そして `GCPtr`
はゼロへの drop がトリガーする付加されたファイナライザを持ち得る
-- *返される*ポインタにとって、そのファイナライザは C 呼び出し側
が値を見る前にすら走り得る、use-after-free。引数位置の `GCPtr` は
決してこれを冒さない。ラッパは自身の戻り値だけを drop し、自身の
引数は決して drop しないからである。

### Integer(GMP)、両方向

`Integer` は両方向で GMP の `mpz_t` を往復するが、どちらの方向も
汎用 `packCFType`/`extractValue` 経路を無変更で再利用しない:

- **引数**: 入ってくる値は生の `mpz_t` であり、`packCFType CFInteger`
  自身の恒等パススルーが仮定する `IDRIS2RC2_Integer*` ではまだ
  ない(その仮定は他のすべての場所で成り立つ。そこでは先行する
  生成コードが既に `IDRIS2RC2_Integer` を構築していた)。新しい
  ヘルパ `idris2rc2_mkIntegerFromMpz`
  (`rc2/support/rc2/memory.c`/`.h`)がまずそれをコピーする:

  ```c
  IDRIS2RC2_Integer *idris2rc2_mkIntegerFromMpz(mpz_t src) {
    IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
    mpz_set(v->v, src);
    return v;
  }
  ```

  `emitExportWrapper` 自身の `argPack` は `CFInteger` を特別扱い
  して、汎用 `packCFType` の代わりにこれを呼ぶ。

- **戻り値**: GMP の `mpz_t` にはそもそも値渡しの C 戻り値形状が
  ないので、`Integer` を返すエクスポートのラッパシグネチャ全体が
  先頭の `mpz_t out` パラメータを得て、自身の C 戻り値型が `void`
  になる -- `%foreign` 側の Integer 戻り値に対する
  `emitGenericForeignWrapper` 自身の同一の out パラメータ規約を
  反映する(`Test54FFIInteger` を参照)。本体は
  `mpz_init(out); mpz_set(out, <extracted value>);` の後に、
  トランポリンされたボックス化結果の明示的な `idris2rc2_drop` と
  素の `return;` が続く。

`rc2/tests/Test59Export/` から適応。両方向を `Int` の 64 ビット
範囲を十分越えた値で行使する:

`Test59Export.idr`:

```idris
%export "C:idris2rc2_test63_add"
addInteger : Integer -> Integer -> Integer
addInteger x y = x + y
```

`Test59Export.h`(`out` は GMP 自身の規約に一致する*最初の*
パラメータ):

```c
extern void idris2rc2_test63_add(mpz_t out, mpz_t x, mpz_t y);
```

伴走 C。GMP 的に正しいが `Int64` 範囲外の値で呼ぶ:

```c
mpz_t a, b, out;
mpz_init_set_str(a, "123456789012345678901234567890", 10);
mpz_init_set_str(b, "1", 10);
mpz_init(out);
idris2rc2_test63_add(out, a, b);
/* out == 123456789012345678901234567891 */
```

上の "実例" と同じビルドレシピ(伴走 `.c` を `.o` にコンパイル、
`IDRIS2_LDFLAGS` 経由で指す)。rc2 自身が必要とする
`nix-shell -p gcc gmp pkg-config` の行に `gmp` が既にある。この
CFInteger セクションが
`rc2/tests/Test59Export/Test59Export.expected` に寄与する行:

```
42
1
```

(`42` = Idris から通常に呼ばれた `addInteger 40 2`; `1` = 伴走 C
自身の GMP 値チェックが成功した。)

### String: 引数と戻り値、異なる所有権規約

`isExportableCFType` は `CFString` をどちらの位置でも許容するが、
専用のラッパ経路を必要としたのは**戻り値**方向だけである -- 引数
`String` は、他のすべての `%foreign`/ネイティブ入力呼び出し箇所が
既に使う同じ汎用 `packCFType CFString`(`idris2rc2_mkString(varName)`、
入ってくる `const char *` を新しく所有される `IDRIS2RC2_String` に
コピーする)を使うので、そのコピー以外に特別な所有権注記を持たな
い。`Test59Export` はこれを直接固定する -- 伴走 C ドライバが素の
文字列リテラル(決して Idris/rc2 管理メモリではない)を渡し、
呼び出し後にそれが無変更で残ることを確認し、rc2 が呼び出し側自身の
バッファをエイリアスも所有もしないことを証明する。`Test59Export`
は戻り値方向をカバーする。それが正しくすべき本物の所有権契約を
持つ方である。

**戻り値**は本物の修正を必要とした: `extractValue` 自身の
`CFString` ケースは、*ボックス化*値自身の malloc されたバッファ
(`((IDRIS2RC2_String*)v)->str`)をコピーせずに直接エイリアスする
-- そのポインタを返して*その後*それの由来元であるボックス化値を
drop する(ラッパの通常の return 後クリーンアップ)と、C 呼び出し
側にダングリングポインタを渡すことになる。`emitExportWrapper` の
`CFString` 戻り値ケースは代わりに:

```c
IDRIS2RC2_Value *r = idris2rc2_trampoline(<call>);
const char *raw = ((IDRIS2RC2_String*)r)->str;
size_t len = strlen(raw) + 1;
char *result = malloc(len);
memcpy(result, raw, len);
idris2rc2_drop(r);
return result;
```

このケースのラッパ自身の C 戻り値型は素の `char *` である --
`const char *`(`%foreign` の借用不変ビュー規約向けの通常の
`cTypeOfCFType CFString` マッピング)では**ない** -- バッファが
今や独立した呼び出し側所有の割り当てであり、呼び出し側が
`free()` することが期待されるポインタに `const` 修飾子を付けるのは
積極的に誤解を招くからである。

**所有権契約**: 返される `char *` は素の独立した `malloc` された
バッファである。C 呼び出し側がそれを完全に所有し、済んだら自身で
`free()` **しなければならない**; 決して任意の `idris2rc2_*` 関数に
渡してはならない(それは `IDRIS2RC2_String` ではなく、その型の
ヘッダを一切持たない)。

`rc2/tests/Test59Export/` から適応:

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

この CFString 戻り値セクションが `Test59Export.expected` に寄与
する行:

```
hello 7
1
```

(`hello 7` = Idris から `putStrLn` 経由で通常に呼ばれた
`greetStr 7`; `1` = 伴走 C 自身の `strcmp`-and-`free` チェックが
成功した。)

### Buffer: 今もスコープ外

`Buffer` はどちらの方向もサポートされない。上記 `String` の戻り値
規約が明示的に解かなければならなかったのと同じ所有権の危険
(誰が割り当てるか、誰が解放するか、どのアロケータで)を共有し、
加えて `String` にはないもの: `Buffer` のサイズは、NUL 終端
`char *` のように自己記述的でないので、`%export` 境界を越えるには
その長さを C 呼び出し側に伝えるなんらかの規約(out パラメータ、
固定最大値、長さ前置き規約...)も必要で、それはまだ設計されて
いない。後で見直すかもしれない。

## `IO`/`PrimIO` 戻り値型の特別扱いと World 引数

`IO`/`IORes` は両方とも本物の `data` 型(`libs/prelude/PrimIO.idr`)
なので、`T1 -> T2 -> IO R` 型のエクスポート自身の正規化された型は
`R` を包む通常の `NTCon` であり、`%foreign` が既に
`PrimIO`/`CFIORes` 戻り値を peel するのと同じやり方で
`Compiler.RC2.DualABI.peelIORes` で peel される。`CFUnit`
(`IO ()` を返すエクスポート)は、戻り値側にネイティブ marshalling
が一切ない特別なケースとして受け入れられる -- ラッパ自身の C
戻り値型は `void` で、トランポリンされた結果は読まれず捨てられる。
`Compiler.RC2.Emit` 自身の生成 `main()` がトップレベルプログラム
の最終結果を同じやり方で捨てるのを反映する。

これの実装中に経験的に確認した(ソース読みだけから仮定したのでは
ない): `main` 自身のよく知られたエントリポイント
(`__mainExpression`、アリティ 0 -- その `%World` トークンは
プログラム全体の最上部で、ラムダリフティングの前に既に一度適用
されている)と異なり、*通常の* `IO`/`IORes` を返す関数は、その
コンパイル済み(`Lifted`)アリティまでずっと、本物の消去されない
末尾 `%World` パラメータ(quantity 1、0 ではない)を今も運ぶ。
コンパイル済み定義自身のアリティに対する素朴なスカラー引数数比較
は、さもなくばすべての IO を返すエクスポートで偽の不一致を投げる;
`Compiler.RC2.RC2.validateExport` はエクスポートの戻り値型が
`CFIORes _` のときこの 1 つの余分なスロットを考慮し、
`emitExportWrapper` は呼び込むときそれをボックス化された `NULL`
定数として供給する -- `Compiler.RC2.Emit.Util` 自身の
`packCFType`/`extractValue` が他のすべての場所で `CFWorld` に
既に使う同じプレースホルダである。

## メモリ: 非 `Unit` 戻り値ごとの明示的な drop

rc2 自身のコンパイル済み出力の通常の Rep 駆動コード経路はすべて、
`Compiler.RC2.RC` の `annotate` パスによって所有権/drop の帳簿付け
を一度、静的に決定され、明示的な `RDrop`/`RFree` ノードとして
ツリーに焼き込まれる。`emitExportWrapper` は手書きの生 C テキスト
で、そのパイプラインの完全に外にあるので、ここでは自身の正しさに
責任を負う: `extractValue` がトランポリンされたボックス化結果の
ネイティブペイロードを読み出した後、ラッパは明示的にそれを
`idris2rc2_drop` する。これは防御的な偏執ではなく本物の修正である
-- `main` 自身のフッタ(プロセスが直後に終了するので最終結果を
決して drop しなくても済む)と異なり、このラッパは外部 C から
任意の回数呼ばれ得るので、ヒープ割り当てする戻り値
(`CFInt`/`CFInt64`/`CFUnsigned64`/`CFDouble`)はさもなくば
呼び出しごとにリークするだろう。drop は無条件である
(値が決して本物のヒープ割り当てでない
`CFChar`/`CFInt8`/.../`CFUnsigned32` に対しても)。`idris2rc2_drop`
は常に unboxed または `NULL` の値に対して安全に no-op する
からである -- その no-op 自体が実装の事故ではなく文書化された
ランタイム保証である理由は `Compiler.RC2.Types.alwaysUnboxed`
自身の doc コメントを参照。`CFInteger` と `CFString` の戻り値は
そもそもこの汎用経路を通らない -- 上記 "スコープ" のそれぞれ専用
セクションを参照 -- が、両方とも同じリーク防止の理由で、ラッパが
呼び出し側に返る前にトランポリンされたボックス化結果の明示的な
`idris2rc2_drop` で今も終わる。

## 実装されていない 2 つのスコープ項目(v1)

- **生成 C ヘッダなし。** ラッパ自身のプロトタイプは、それを呼ぶ
  どの C コードによっても手で `extern` 宣言されなければならない
  (パターンは `rc2/tests/Test59Export.h` を参照)-- rc2 はまだ
  生成 `.c` と並んで自身の `.h` を出力しない。
- **今も有界なスコープ**、上記 "スコープ" の通り -- スカラー、
  `Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr`(引数のみ)、`Integer`、
  `String`、ポインタ経由の構造体は今やサポートされるが、
  `Buffer`、他の任意のユーザー定義 ADT(`List`、`Maybe`、または
  アプリケーション自身の `data` 型)、関数/クロージャの引数または
  戻り値は今もされない(そのすべてを `%foreign` は逆方向で、少な
  くともこれらのいくつかについて既にサポートする)。

## ライブラリとしてリンク(`--directive nomain`)

すべての生成 `.c` は、`__mainExpression_0()` を呼んで結果を
トランポリンする自身の C `main()`(`Compiler.RC2.Emit` の
`footer`)で無条件に終わっていた。通常の単体実行ファイルには
問題ないが、自身の `main()` を定義する伴走 `.c` ファイル -- まさに
`%export` 消費側が自然に望む形状、`main` を所有しエクスポート
シンボルへ直接呼び込む手書きの C ドライバ -- は重複シンボルの
リンクエラーを生むことを意味した。`--directive nomain` /
`%cg rc2 nomain` がこれを修正する: `footer` は完全にスキップされ、
生成 `.c` は自身の `main()` を持たず外部のものと並んでクリーンに
リンクする。完全な検証済みウォークスルーは上記 "実例"
("バリアント: 外部 C が `main` を所有する")を参照。

その生成 `main()` は、ランタイムライフサイクルフックが呼ばれる
場所でもある(`doc/runtime-lifecycle.md`)。`nomain` では、手書きの
ドライバがその仕事を引き受ける: 最初のエクスポート呼び出しの前に
一度 `idris2rc2_rtInit()`(`setlocale(LC_ALL, "")` を実行する)を、
プロセス終了前に `idris2rc2_rtFinish()`(`fflush`)を呼ぶ。両方
とも `runtime.h` に宣言され、`idris2rc2_runtime.h` アンブレラ経由
で到達可能。`rtInit` をスキップしてもクラッシュしない -- プログラム
は単に `"C"` ロケールに留まる、フック前の振る舞い。

## DeadCode の生存

`%export` された名前は、プログラムの他の何かがそれを呼ぶか
どうかにかかわらず `Compiler.RC2.DeadCode.pruneDeadDefs` が決して
drop してはならないルートである -- `Compiler.RC2.RC2.compileExpr`
自身の `roots` リストは、この機能がそのリストに何かを投入する
ずっと前(実際上常に `[]` だった)から、まさにこの理由で
`exported cdata` の名前を既に含んでいた。これを本物に配線する間に
1 つの本物のバグが見つかり修正された:
`Compiler.Common.getExports` は各エクスポート名を `toFullNames`
ではなく `resolved` 経由で解決するので、`exported cdata` 自身の
`Name` は `Resolved`(コンテキストインデックス)形式である一方、
`pruneDeadDefs` が歩く `RCDef` パイプラインのすべてのエントリは
フル名でキー付けされる -- 構造的な `Name` 等価チェックで、
`Resolved` 形式のルートは決して実際にはマッチしない。`roots` は
今、自身のコピーを再導出(して間違える)代わりに、`validateExport`
自身の `getFullName` 解決済み名前を再利用する。`main` が決して
呼ばない 3 つ目のエクスポート(`Test59Export.idr` の `unused`)で
確認済み: その自身のラッパと自身の元の常にボックス化された
エントリポイント(`idris2rc2_test_unused`/`Main_unused`)の両方が
今も生成 C に現れる。

## 参照テスト

`rc2/tests/Test59Export/`(`.idr` + その `.c`/`.h` 伴走)は 1 つの
統合テストで、その 7 つのセクションがすべての `%export` CFType
形状をカバーし、各々が通常の Idris コードからと素の手書き C から
(Idris/rc2 API を一切関与させずにエクスポートシンボルを直接呼ぶ
`%foreign` 束縛の C 関数経由で)両方で呼ばれる。`verify.sh` の
`NO_REFC_DIFF_TESTS`(本物の RefC は `%export` marshalling を一切
持たないので、`--cg refc` 比較ビルドは単に伴走 `.c` ファイルの
`extern` 宣言のリンクに失敗する)と `LEAK_SENSITIVE_TESTS`
(CFInteger/CFString セクションの copy-in/copy-out 所有権経路の
ため)に列挙されている。

- §1(旧 `Test59ExportScalar`)-- 2 つのスカラー関数
  (`Int`/`Double`)に加えて、上記 DeadCode 生存保証を証明する
  3 つ目の他では未使用のエクスポート。
- §2(旧 `Test60ExportPtr`)-- `CFPtr`、両方向、アドレス恒等性と
  活性を検査。
- §3(旧 `Test61ExportStruct`)-- `CFStruct`、ポインタ経由、加えて
  上記 "スコープ" で注記した構造体 typedef の活性の注意事項。
- §4(旧 `Test62ExportGCPtr`)-- `CFGCPtr`、引数のみ。
- §5(旧 `Test63ExportInteger`)-- `CFInteger`、両方向、GMP 範囲の
  値。
- §6(旧 `Test64ExportString`)-- `CFString` 戻り値とその
  呼び出し側が `free()` する所有権契約。
- §7(旧 `Test65ExportStringArg`)-- `CFString` 引数、呼び出し側
  自身のバッファがコピーされ、rc2 によって決してエイリアスも解放も
  されないことを確認。
