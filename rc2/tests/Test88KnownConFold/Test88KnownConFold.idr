module Main

-- Constructors built and then only taken apart in the same function
-- (`rc2/doc/constructor-escape-analysis.md`).
--
-- `bump`: a `Just` that is only ever `case`-matched, twice, never
-- escapes -- `Compiler.RC2.ConstFold` resolves both matches against it
-- and drops the construction. Its native `Int` field is read once as
-- Boxed (the first match's result) and once natively, so this also
-- covers the field being boxed once rather than aliased.
--
-- `keep`: the matched `Just` is rebuilt and returned on one path, so
-- the local stays Boxed-shared, not re-boxed per use.
--
-- `score`: an inlined `Either` bind chain matched straight away, the
-- shape `Compiler.RC2.PushCon` ("Rewrite B") pushes the `case` into.
-- Every tail meets its own alt, so the final `Right (a + b)` is never
-- built.
--
-- `useHalf` and the `M` monad chain: output-only coverage.

record M a where
  constructor MkM
  runM : IO (Either String a)

pureM : a -> M a
pureM x = MkM (pure (Right x))

bindM : M a -> (a -> M b) -> M b
bindM (MkM act) f = MkM $ do
  Right v <- act
    | Left err => pure (Left err)
  runM (f v)

failM : String -> M a
failM e = MkM (pure (Left e))

liftM : IO a -> M a
liftM act = MkM (map Right act)

step : Int -> M Int
step n = if n > 100 then failM "too big" else pureM (n * 2)

chain : Int -> M Int
chain n = step n `bindM` \a => step (a + 1) `bindM` \b => liftM (pure (a + b))

half : Int -> Maybe Int
half n = if n < 0 then Nothing else Just (n `div` 2)

%noinline
useHalf : Int -> Int
useHalf n = case half n of
  Just h => h + 1
  Nothing => 0

-- a Just that is matched, and also escapes on one path
%noinline
keep : Int -> Maybe Int -> (Int, Maybe Int)
keep n fallback =
  let m = Just (n + 1) in
  case m of
    Just v => if v > 10 then (v, m) else (v, fallback)
    Nothing => (0, fallback)

-- a Just only ever taken apart, twice, so it never escapes
%noinline
bump : Int -> Int
bump n =
  let m = Just (n + 1) in
  (case m of Just v => v; Nothing => 0) + (case m of Just w => w * 2; Nothing => 1)

checkA : Int -> Either Int Int
checkA x = if x > 50 then Left x else Right (x * 3)

checkB : Int -> Either Int Int
checkB x = if x < 0 then Left (x + 1) else Right (x + 7)

%inline
bindE : Either Int a -> (a -> Either Int b) -> Either Int b
bindE (Left e) _ = Left e
bindE (Right x) f = f x

%noinline
score : Int -> Int
score x = case checkA x `bindE` \a => checkB a `bindE` \b => Right (a + b) of
  Left e => e + 13
  Right v => v + 1009

report : Either String Int -> IO ()
report (Left e) = putStrLn ("error: " ++ e)
report (Right v) = printLn v

main : IO ()
main = do
  report !(runM (chain 3))
  report !(runM (chain 70))
  printLn (useHalf 9)
  printLn (useHalf (-4))
  printLn (score 5)
  printLn (score 60)
  printLn (bump 4)
  printLn (bump 10)
  printLn (keep 20 Nothing)
  printLn (keep 1 (Just 7))
