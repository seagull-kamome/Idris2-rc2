module Main

-- `BenchStructReturn`'s chain with payloads past the small-int cache:
-- every `Right` holds an `Int` above 100, which a Boxed field has to
-- allocate afresh at each level. With struct return the `Int` rides in
-- the struct natively (`Ret1:1=Int`, doc/struct-return.md), so the
-- chain allocates nothing at all.
--
-- A/B it with `--directive nostructreturn`.

step : Int -> Int -> Either String Int
step 0 x = if x < 0 then Left "neg" else Right x
step d x = case step (d - 1) (x + 1) of
             Left e => Left e
             Right v => Right (v + 1)

run : Int -> Int -> Int -> Int
run n i acc =
  if i >= n then acc
  else case step 4 (i + 1000) of
         Left _ => run n (i + 1) acc
         Right v => run n (i + 1) (acc + v)

main : IO ()
main = printLn (run 5000000 0 0)
