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



