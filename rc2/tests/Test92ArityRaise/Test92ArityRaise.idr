module Main

-- World arity raising (rc2/doc/world-arity-raising.md).

-- Upstream's `Core`: a record around IO (Either Error a).
record Core t where
  constructor MkCore
  runCore : IO (Either String t)

pure' : a -> Core a
pure' x = MkCore (pure (Right x))

bind : Core a -> (a -> Core b) -> Core b
bind (MkCore act) k = MkCore $ do
  r <- act
  case r of
    Left e => pure (Left e)
    Right x => runCore (k x)

throw' : String -> Core a
throw' e = MkCore (pure (Left e))

-- Matches on its argument, so the world's lambda sits inside each
-- branch: one branch a constant closure, the other a capturing one.
sumPos : List Int -> Core Int
sumPos [] = pure' 0
sumPos (x :: xs) =
  if x < 0 then throw' "negative"
  else sumPos xs `bind` \s => pure' (s + x)

-- Delegates in a tail to another raised function.
sumTwice : List Int -> Core Int
sumTwice [] = pure' 0
sumTwice xs@(_ :: _) = sumPos (xs ++ xs)

-- A plain IO function of the same shape.
printAll : List Int -> IO ()
printAll [] = pure ()
printAll (x :: xs) = do
  printLn x
  printAll xs

main : IO ()
main = do
  r <- runCore (sumPos [1, 2, 3, 4])
  printLn r
  r2 <- runCore (sumPos [1, -2])
  printLn r2
  r3 <- runCore (sumTwice [5, 6])
  printLn r3
  -- The closures kept in a list and run later: still the wrappers.
  let acts = map sumPos [[1], [2, 3], [-1]]
  rs <- traverse runCore acts
  printLn rs
  printAll [7, 8, 9]
