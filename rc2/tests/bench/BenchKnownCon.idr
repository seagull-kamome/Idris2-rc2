module Main

-- A constructor built and only ever taken apart in the same function
-- -- the shape `Compiler.RC2.ConstFold`'s known-constructor fold
-- removes (`doc/constructor-escape-analysis.md`, "Rewrite A").
--
-- `step` builds a `Just` and matches it twice. Without the fold every
-- call allocates the `Just` cell plus a box for its `Int` field (the
-- value is past `idris2rc2_mkInt64`'s small-int cache); with it both
-- matches resolve at compile time, the field is read natively, and
-- nothing is allocated.
--
-- `%noinline` keeps `step` a real call per iteration; calling it from
-- two places keeps `Compiler.RC2.LateInline` from splicing it.
--
-- A/B it with `--directive noknowncon`.

%noinline
step : Int -> Int
step x =
  let m = Just (x * 3 + 1000) in
  (case m of Just v => v `mod` 1009; Nothing => 0) +
  (case m of Just w => w `mod` 7; Nothing => 1)

run : Int -> Int -> Int
run acc 0 = acc
run acc n = run ((acc + step n) `mod` 1000003) (n - 1)

main : IO ()
main = do
  printLn (step 1)
  printLn (run 0 5000000)
