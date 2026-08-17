# Idris2コード規約

気軽にトップレベル関数を作らない。複数箇所で使用される場合を除き、可能な限り
where節のローカル関数にスコープを閉じ込める。

totalの関数は必要が無い限りtotalを維持し、コンパイラに安全性を検査させる。
新規に作成する関数もtotalである事が望ましいが、coveredでも十分許容する。

人間が指示しない限り、coveredの関数を手間を掛けてtotalにリファクタリングしなくてよい。
コードリファクタリングを依頼された時に作業を提案する。

asパターンを活用する。
case ...
❌️  Foo a b c => Foo a b c
⭕️  a@(Foo _ _ _ ) => a

else節を活用する。
❌️ case ...
     ConA a b => exprA
     ConB c d => exprB c d
     ConC e f => exprA
     conD g h => exprA
⭕️ case ...
     ConB c d => exprB c d
     _ => exprA



