module Main

-- Post-RC fold of a closure applied at once (rc2/doc/world-arity-raising.md's
-- "Post-RC fold"). `bind` is not `%inline`, so LateInline splices it
-- only after RC annotation: `run` then builds `step`'s closure and
-- applies it at once (one argument, exactly what it misses), and builds
-- its continuation, applied with one more argument than it misses in
-- the `Right` branch and only dropped in the `Left` one.

record Core t where
  constructor MkCore
  runCore : IO (Either String t)

pure' : a -> Core a
pure' x = MkCore (pure (Right x))

throw' : String -> Core a
throw' e = MkCore (pure (Left e))

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
  r <- runCore (run 1000 0 0)
  printLn r
  r2 <- runCore (run 3 (-10) 0)
  printLn r2
