# 静的クロージャ

(原文: `doc/static-closures.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.Emit.Util.staticClosure`。キャプチャした値がすべて定数であるクロージャを、構築のたびに`idris2rc2_mkClosure`を呼んでフィールドごとに1回ずつストアする代わりに、`RCConstCon`と同じく不死の、ファイルスコープの静的データにする。

## なぜEmitで行うのか

`Control.Task`の`pure ()`は、unitとworldを引数とする`pure`の末尾呼び出しである。IRの上ではこれは`RAppName`であり、末尾呼び出しがトランポリン用のクロージャになるのは`Emit`(`tryBuildClosureInto`)の中だけである。そのため`ConstFold`がそこでクロージャを目にすることはない。また`RCConstPartial`はキャプチャした値を持たず、持たせるには`RCLocal`にマッチするすべての箇所(約55箇所)を変える必要がある。`Emit`の規則に要るのは、クロージャを構築する時点でのキャプチャした値だけである。

## 規則

キャプチャした値がすべて`RCNull`、`RCErased`、`RCWorld`、定数形式(`RCConstCon`、`RCConstPartial`)、またはリテラル(`RCConst`。ボックス化された定数として出力される。即値の整数か、文字列のような静的データ)であり、そのCの式がアドレス、`NULL`、`IDRIS2RC2_IMM_*`のいずれかであること。それ以外のもの(式が`mk...`の呼び出しになる`RCEmptyCon`もこれに含まれる)は、ヒープ上のクロージャのままにする。条件を満たせば、`makeClosureInto`は次の定義を用意する。

```c
static IDRIS2RC2_ConstClosureArgs2 const constclosure_N =
  { .header = IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE), .arity = 3, .filled = 2,
    .fn = (void *)f, .args = { NULL, NULL } };
```

そして出力先はそのアドレスを受け取る。`IDRIS2RC2_ConstClosureArgsN`(1から20。`idris2rc2_rt.c`のディスパッチの`switch`の範囲)は、固定長の`args[N]`を持つ`IDRIS2RC2_Closure`である(Cには、フレキシブル配列メンバに対する静的な初期化子がない)。

これが健全である理由: ヘッダは不死なので、クロージャとそのキャプチャした値の`dup`と`drop`は何もしない。`idris2rc2_isUnique`は偽になり(共有された静的データをその場で伸ばすことはない)、トランポリンによるディスパッチ済みクロージャの解放は飛ばされる。飽和した静的クロージャは、返されるたびにトランポリンによって実行される。それが渡す引数は、どこからも解放されない定数である。静的クロージャは決して解放されない。デッドな`let`に対する`RFree`が選ばれるのは、キャプチャした値に変数を含む部分適用の場合だけである(`RC.idr`の`freeableShape`)。静的データは箇所をまたいで共有しない(重複除去はしない)。それぞれ数ワードにすぎない。

## 測定結果

`TestAsyncHTTPServer`: 静的データが15個。1コネクション、1スレッドでの`GET /hello`1回あたりのユーザー空間の命令数: 259 000 -> 251 000(約3パーセント)。

テスト: `rc2/tests/Test133StaticClosure/`。
