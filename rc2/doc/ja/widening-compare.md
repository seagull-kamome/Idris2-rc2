# `Integer`に拡大変換した整数とリテラルの比較 (`Compiler.RC2.ConstFold`)

(原文: `doc/widening-compare.md`。内容が乖離した場合は原文を正とする。)

`x : Int`を`Integer`として読んでリテラルと比較する`0 <= cast x`は、これまで`mkInt64`によるボックス化、`idris2rc2_cast_Int64_to_Integer`の呼び出し、`Integer`の比較、ボックスの`drop`になっていた。より狭い型から`Integer`への`cast`は値を変えないので、比較はその狭い型のまま行える。また、その型の範囲外にあるリテラルとの比較は、その場で結果が決まる。

## 書き換え

`ConstFold`は`let v = cast-T-Integer a`をそれぞれ記録する(`Env.widened`)。`Integer`上の`RCmpCase`で、一方の側が`v`、もう一方がリテラル`c`であるものは、`T`の範囲を`lo..hi`として次のように書き換える。

- `c`が`lo`より小さいか`hi`より大きい場合: 答えはどの`x`でも同じなので、選ばれる分岐がそのまま結果全体になる(`holdsOutside`)。`==`は偽になる。
- それ以外: `a`と`c`の`T`上の比較(`Narrowed`)にする。オペランドの順序は元のまま保つ。

`let v`は、分岐がまだ使っていれば残り、何も使わなければ消える。その後`Sink`が、1つの分岐だけが読む`cast`をその分岐の中へ移す。

`T`は`Int`、`Int8`..`Int64`、`Bits8`..`Bits64`、`Char`である。サロゲートの範囲にある`Char`リテラルは書き換えない。キャスト同士の比較(`cast x < cast y`)は扱わない。扱うのはキャストとリテラルの比較だけである。

## 計測

`rc2-norepl`のIRでは、`Integer`の比較759個のうち66個がこの種類だった(57個が`Int`由来で、そのほとんどは`integerToNat`の`0 <= cast x`)。

## テスト

`Test162WidenCompare`は、すべての型について、オペランドの両方の順序と、範囲内および両側の範囲外のリテラルを試す。IRの`Integer`比較は、`--directive noconstfold`のときの35個に対して2個になり、出力は同じである。
