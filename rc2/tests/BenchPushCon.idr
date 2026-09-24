module Main

-- A `case` on a value whose own branches end in constructors -- the
-- `Either` bind chain `Compiler.RC2.PushCon` pushes the `case` into
-- (`doc/constructor-escape-analysis.md`, "Rewrite B").
--
-- Once `bindE` is inlined, `score` matches on a nested `case` whose
-- tails build `Left e` / `Right (a + b)`. Without the push each call
-- builds that result and matches it straight away; the `Right`'s
-- field is a native `Int` sum, so building it also boxes the sum
-- (past `idris2rc2_mkInt64`'s small-int cache). With the push each
-- tail meets its own alt, `ConstFold` folds it, and the sum stays
-- native -- fewer allocations per call.
--
-- `check1`/`check2` each have one caller, so `Compiler.RC2.Inline`'s
-- Criterion B inlines them before the push runs, and their own
-- constructors are folded away along with the chain's.
--
-- A/B it with `--directive nopushcon`.

check1 : Int -> Either Int Int
check1 x = if x > 9000000 then Left x else Right (x * 3)

check2 : Int -> Either Int Int
check2 x = if x < 0 then Left (x + 1) else Right (x + 7)

%inline
bindE : Either Int a -> (a -> Either Int b) -> Either Int b
bindE (Left e) _ = Left e
bindE (Right x) f = f x

%noinline
score : Int -> Int
score x = case check1 x `bindE` \a => check2 a `bindE` \b => Right (a + b) of
  Left e => e + 13
  Right v => v + 1009

run : Int -> Int -> Int
run acc 0 = acc
run acc n = run ((acc + score n) `mod` 1000003) (n - 1)

main : IO ()
main = do
  printLn (score 5)
  printLn (run 0 5000000)
