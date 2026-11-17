# `Data.Nat.isLTE`と`lte`を定数時間にする (`Compiler.RC2.NatMagic`)

(原文: `doc/nat-magic.md`。内容が乖離した場合は原文を正とする。)

upstreamの(`Data.Nat`の)`isLTE`と`lte`は、引数を`S`1つずつ分解していく。`Nat`は実行時には`Integer`なので各ステップは安価だが、ステップ数は`min m n + 1`になる。しかも`isLTE`は末尾呼び出しではない。各ステップで`Yes (LTESucc prf)`を組み立て直す(これは`prf + 1`である。`LTE`は`Nat`と同じ形をしているので、これも数値になる)か、反証を合成する。`natToFin k n`は`isLTE (S k) n`を呼ぶ。upstreamの`natHack`(`Compiler.Opts.Constructor`)は、`Prelude.Types`の`plus`、`minus`、`compareNat`ほか数個の関数をプリミティブに置き換えるが、この2つは対象外である。

`applyNatMagic`は、名前付きのcase tree上で(プログラム全体でもモジュール単位でも)他の処理より先に、この2つの定義を1回比較するだけの本体に差し替える。

- `lte m n`は`Integer`上の`m <= n`になる。
- `isLTE m n`は、`m <= n`のとき`Yes m`になる(証明`LTESucc (... LTEZero)`は`LTESucc`の個数、すなわち`m`という数値である)。それ以外のときは、クラッシュする関数を持つ`No`になる(この関数は`Void`への関数なので、証明を与えて呼び出すことはできない)。

したがって`isLT`、`isGTE`、`natToFin`をはじめ、すべての呼び出し元も定数時間になる。`--directive nonatmagic`を指定するとupstreamの定義を使う。

## 計測

lambda-rogueのテストスイートは、マップを読み込む際にタイルごとに`natToFin x 80`と`natToFin y 22`を呼ぶ。

| | 命令数 | 時間 |
|---|---|---|
| `nonatmagic` | 34.17 G | 3.76 s |
| デフォルト | 21.01 G (-38.5%) | 2.37 s |

残りのコストの最上位は`Data.Vect.index`(リストをたどる処理。残りの43%)である。

`Test182NatMagic`は、`isLTE`(実行時に数えた`Yes`の証明の大きさ)、`lte`、`gte`、`lt`、`natToFin`、`isLT`を境界値で試し、`nonatmagic`のときと同じ結果になることを確かめる。`isLTE`と`lte`のIRは何も呼び出さない。
