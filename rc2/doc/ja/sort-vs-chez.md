# Chezとの`sort`の比較: 積み重なった原因 (2026-09-26計測)

(原文: `doc/sort-vs-chez.md`。内容が乖離した場合は原文を正とする。)

`TODO.md`から移した。未解決のもの(末尾の内訳)は`TODO.md`に残している。

疑似乱数の`Int` 100万個に対する`Data.List.sort`は、rc2で4.18s、Chezで1.23sかかった。原因1は修正済みであり(`Compiler.RC2.DeadArgs`、`rc2/doc/dead-args.md`)、これで`sort`は3.21sになった。さらに`rc2/doc/constructor-layout.md`でコンストラクタのセルを小さくして3.12sになった。それ以外の原因は後に修正した(下の一覧)。各原因は、`Data.List`自身のコードのコピーに対する実験で切り分けた。

| 版 | 時間 |
|---|---|
| `Data.List.sort`(`DeadArgs`より前。`DeadArgs`ありでは3.21s) | 4.18s |
| 同じコードを`Main`にコピーしたもの(B) | 3.21s |
| Bの`splitRec`に、使われない受け渡しだけの引数を1つ加えたもの | 4.19s |
| Bの`order x y`を`compare x y`に置き換えたもの(特殊化) | 2.62s |
| Bを`x < y`に特殊化したもの | 2.03s |
| `x < y`版で、`dup`/`drop`を非アトミックにし、mimallocを使ったもの | 0.99s |

1. **修正済み: 使われない引数が入力リストを生かし続けていた**(約1.0s)。フロントエンドが`where`に付け加える引数(`KNOWN-BUGS.md`)が、`splitRec`のループの間ずっとリストの先頭を保持し、セルの再利用を妨げていた。`rc2/doc/dead-args.md`を参照。
2. **修正済み: 比較関数がまったく特殊化されない。** SpecClosureは、`sortBy`から`mergeBy`へそのまま渡されるクロージャを追うようになった。`sort`は1.49sから1.11sになり、Chezの1.23sを下回った(`rc2/doc/speculative-closure-specialization.md`の「Transitive specialisation」)。
3. **修正済み: アトミックな参照カウント。** プログラムがマルチスレッドになるまでは通常の操作にした。`sort`は3.17sから2.45sになった(`rc2/doc/hybrid-refcount.md`)。
4. **修正済み: glibcのmalloc**(mimallocで-33%)。小さなセルについては、rc2独自のセルプールがこれを置き換える(`rc2/doc/small-object-allocator.md`の「Results」)。
5. **修正済み: ボックス化された`Int`。** 62ビットに収まる`Int`は即値になった(`rc2/doc/immediate-ints.md`)。

`DeadArgs`の後(3.21s)に計測し直した結果は次のとおりである。

| 版 | 時間 |
|---|---|
| そのまま | 3.21s |
| `dup`/`drop`を非アトミックにしたもの | 2.55s |
| mimalloc | 2.45s |
| 両方 | 1.81s |

1.81sの実行の内訳は次のとおりである。
- **TRMCを適用した`mergeBy`のループが42%を占める。** その約3分の2はメモリのストールである。
  - リストのセルのフィールドのロード(ループの37%)。
  - 比較関数のために`dup`する際の、ボックス化された`Int`の参照カウントへのアクセス(30%)。
- **比較関数の呼び出し経路が約28%を占める。** `applyClosureN`、`dispatchFn`、wrapper、worker、`trampoline`である。確保はなく、比較1回あたり約25nsかかる。
- **`split`が8%、解体が5%である。**
