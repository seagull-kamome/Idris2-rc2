module Main

-- The `step` chain of `BenchStructReturn`, written against a `Core`
-- clone (a record around `IO (Either String a)`) the way upstream's own
-- code is (`pure` and `>>=` are `%inline` there, too): `step` matches
-- on its argument, so the elaborator puts the
-- world's lambda inside each branch and every call returns a closure
-- its caller applies at once (`doc/world-arity-raising.md`).
--
-- A/B it with `--directive noarityraise`.

record Core t where
  constructor MkCore
  runCore : IO (Either String t)

%inline
pure' : a -> Core a
pure' x = MkCore (pure (Right x))

throw' : String -> Core a
throw' e = MkCore (pure (Left e))

%inline
bind : Core a -> (a -> Core b) -> Core b
bind (MkCore act) k = MkCore $ do
  r <- act
  case r of
    Left e => pure (Left e)
    Right x => runCore (k x)

step : Int -> Int -> Core Int
step 0 x = if x < 0 then throw' "neg" else pure' (mod x 64)
step d x = step (d - 1) (x + 1) `bind` \v => pure' (v + 1)

run : Int -> Int -> Int -> Core Int
run n i acc =
  if i >= n then pure' acc
  else step 4 i `bind` \v => run n (i + 1) (acc + v)

main : IO ()
main = do
  r <- runCore (run 5000000 0 0)
  printLn r
