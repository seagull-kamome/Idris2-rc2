module Main

-- Regression/smoke test for constructor-destructured field native
-- shadowing (Compiler.RC2.ConAltNative, see TODO.md's "Native
-- representation for constructor-destructured fields").

data Acc = MkAcc Int Int

-- Destructures and immediately reconstructs the same shape -- exercises
-- Compiler.RC2.Reuse's constructor-reuse-in-place path interacting with
-- native-promoted fields (the whole reason the first, reverted
-- implementation attempt leaked).
step : Acc -> Acc
step (MkAcc x y) = MkAcc (x + 1) (y + 2)

sumAcc : Nat -> Acc -> Acc
sumAcc Z acc = acc
sumAcc (S k) acc = sumAcc k (step acc)

showAcc : Acc -> String
showAcc (MkAcc x y) = "(" ++ show x ++ ", " ++ show y ++ ")"

-- A field read natively more than once within the same alt -- the
-- actual optimisation this pass exists for (cache the unboxed value
-- once instead of repeating the unbox at every read).
repeatedRead : Acc -> Int
repeatedRead (MkAcc x y) = x + x + x + y

-- The same field read both natively *and* in a Boxed context within
-- the same alt -- `x`'s own native use (`x + y`) and Boxed use
-- (`show x`) must coexist correctly; `y` is read natively only.
mixedUse : Acc -> String
mixedUse (MkAcc x y) = "sum=" ++ show (x + y) ++ " x=" ++ show x

main : IO ()
main = do
  let acc = sumAcc 200000 (MkAcc 0 0)
  putStrLn (showAcc acc)
  printLn (repeatedRead (MkAcc 5 7))
  putStrLn (mixedUse (MkAcc 3 4))
