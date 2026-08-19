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

-- `x` read natively twice (`x + x`) *and* in a Boxed context twice
-- (`show x` appearing twice); `y` read in a Boxed context once. Direct
-- exercise of `reannotateFieldOwnership`'s own dup-insertion logic
-- across more than one surviving Boxed-context occurrence of the same
-- field.
multiBoxedUse : Acc -> String
multiBoxedUse (MkAcc x y) =
  show x ++ "+" ++ show x ++ "=" ++ show (x + x) ++ " y=" ++ show y

data Choice = ChoiceA | ChoiceB

-- The destructured field's own Boxed-context use appears in only one
-- of two nested branch arms (a `case` on `Choice`, inside the `MkAcc`
-- alt's own body): `x` is read only natively on the `ChoiceA` arm, but
-- also in a Boxed context on the `ChoiceB` arm -- the exact asymmetric
-- shape `finalizeBranch` exists to drop `x` correctly on the arm that
-- never touches it while leaving the other arm's own Boxed use intact.
branchingUse : Acc -> Choice -> String
branchingUse (MkAcc x y) ChoiceA = show (x + y)
branchingUse (MkAcc x y) ChoiceB = show x ++ "," ++ show y

main : IO ()
main = do
  let acc = sumAcc 200000 (MkAcc 0 0)
  putStrLn (showAcc acc)
  printLn (repeatedRead (MkAcc 5 7))
  putStrLn (mixedUse (MkAcc 3 4))
  putStrLn (multiBoxedUse (MkAcc 6 9))
  putStrLn (branchingUse (MkAcc 1 2) ChoiceA)
  putStrLn (branchingUse (MkAcc 1 2) ChoiceB)
