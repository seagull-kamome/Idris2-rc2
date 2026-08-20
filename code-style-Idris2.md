# Idris2コード規約

気軽にトップレベル関数を作らない。複数箇所で使用される場合を除き、可能な限り
where節のローカル関数にスコープを閉じ込める。

totalの関数は必要が無い限りtotalを維持し、コンパイラに安全性を検査させる。
新規に作成する関数もtotalである事が望ましいが、coveredでも十分許容する。

人間が指示しない限り、coveredの関数を手間を掛けてtotalにリファクタリングしなくてよい。
コードリファクタリングを依頼された時に作業を提案する。

## asパターンを活用する
パターンマッチしたあと結局同じ値を返す場合はasパターンを使って簡略化する。
例：
case ...
  Foo a b c => Foo a b c
  a@(Foo _ _ _ ) => a

無用の変数はつくらない事。以下はaが無用。
NG例：
  a@(Foo _ _ x) => x


## else節を活用する。
NG例：
 case ...
     ConA a b => exprA
     ConB c d => exprB c d
     ConC e f => exprA
     conD g h => exprA

ベター：
 case ...
     ConB c d => exprB c d
     _ => exprA


## 型レベル証明(erased proof)でコンパイル時制約を入れる

「このコンストラクタ/この値はここには来ない」という不変条件は、
コメントや実行時crashではなく、可能な限り`0`使用回数(erased)の証明を
関数・コンストラクタの引数として持たせて型で保証する。

```idris2
data IsFoo : MyType -> Type where
     ItIsFoo : IsFoo (Foo x)

useFoo : (v : MyType) -> {0 prf : IsFoo v} -> ...
```

erasedな証明は実行時コストゼロ(値としては消去される)。`Bar`側に
対応するコンストラクタが無ければ、`useFoo (Bar ...)`は型エラーになり
`useFoo`の実装側で`Bar`ケースを書く必要が無くなる(coverage checker
が自動的に除外する)。

### erased引数の制約(要検証・要注意)

- **直接インデックスされた証明**(`IsFoo v`のように証明の型自体が`v`に
  依存し、`v`が決まれば証明のコンストラクタが一意に定まる形)なら、
  値`v`と証明`prf`を同時にパターンマッチしても(あるいは`prf`に一切
  触れなくても)、coverage checkerが対応コンストラクタの無いケースを
  自動的に構成不可能と判定してくれる。
- **ラップされた/間接的な証明**(`data Q v = Wrap (P v)`のような、
  別の証明を包むだけの直和型)は、erasedな引数の位置でネストした
  コンストラクタパターン(`{prf=Wrap ItIsFoo}`)を分解しようとすると
  `Can't match on ... (Erased argument)`で失敗する。回避策: 値`v`の
  パターンだけで分岐し、`prf`は`{prf=_}`のように触れないか、右辺で
  必要な狭い証明を値から新規に構築し直す(既存の`prf`を分解して使い
  回さない)。
- **erasedな証明を非erased(quantity 1)の引数へ渡すことはできない**
  (0→1は不可)。逆にquantity 1の値をerased引数へ渡す(1→0の弱化)は
  常に可能。証明を複数の関数へリレーする設計では、経路の全区間で
  quantityを揃える(全部erasedにするか、途中で意図的に1へ昇格させる
  別の構築をする)。
- パターンの左辺で`{prf}`/`{prf=_}`のように一度も触れないと、
  コンパイラがその引数の存在を認識できず、他のケースを`impossible`
  と判定できないことがある。最低限`impossible`にしたい節にだけ
  `{prf=_}`を明示すれば足り、実装のある他の節は`prf`に触れなくて
  よい場合が多い。

### `mutual`ブロックとdocコメント

`mutual`キーワード自体の直前に`|||`docコメントを置くとパースエラーに
なる(`Couldn't parse declaration`)。コメントは`mutual`ブロックの中の
最初の宣言の直前に書く。

```idris2
-- NG
||| Doc comment
mutual
  data Foo : Type where ...

-- OK
mutual
  ||| Doc comment
  data Foo : Type where ...
```

### 多重定義された中置演算子のセクション記法

`(::)`のように複数モジュールで多重定義された中置演算子は、部分適用の
セクション記法(`(p ::)`)だと曖昧性解消に失敗することがある
(`p is not accessible in this context`のようなエラー)。ラムダ式で
明示的に書く方が確実。

```idris2
-- 曖昧になりうる
map (p ::) xs

-- 確実
map (\ps => p :: ps) xs
```

### 独自ラッパー型より先に標準ライブラリを確認する

「値と証明のペア」「リストの各要素についての証明」が必要な場面では、
独自の`record`/`data`を新設する前に`Data.DPair`(`Subset type pred`
-- 値保持・証明部分`snd`がerased、`Exists`-- 逆に値部分がerased)や
`Data.List.Quantifiers`(`All`/`Any`)を確認する。多くの場合そのまま
使え、`Eq`/`Ord`/`Show`等の既存instanceも流用できる。


