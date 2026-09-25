module Main

-- A chain of calls, each switching on the `Either` the level below
-- returns and rebuilding it -- the shape of `Core`'s bind chains, and
-- the target of struct return (`doc/struct-return.md`). Every payload
-- stays below 100 so `idris2rc2_mkInt64` hands back a static box: what
-- is measured is the `Either` cell itself.
--
-- Today the chain allocates one cell at the bottom, rebuilds it in
-- place at every level (`reuse=`) and frees it at the top. With struct
-- return the result travels as a `{tag, f0}` pair in registers and no
-- cell is built at all.
--
-- A/B it with `--directive structreturn` (opt-in for now).

step : Int -> Int -> Either String Int
step 0 x = if x < 0 then Left "neg" else Right (mod x 64)
step d x = case step (d - 1) (x + 1) of
             Left e => Left e
             Right v => Right (v + 1)

run : Int -> Int -> Int -> Int
run n i acc =
  if i >= n then acc
  else case step 4 i of
         Left _ => run n (i + 1) acc
         Right v => run n (i + 1) (acc + v)

main : IO ()
main = printLn (run 5000000 0 0)
