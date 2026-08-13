module Main

-- Exercises Compiler.RC2.MutualLoop's merge-and-goto conversion for
-- groups of >= 2 mutually tail-recursive functions. Test9SelfTailLoop's
-- isEvenM/isOddM specifically confirmed these are NOT touched by the
-- self-tail-call-only pass (Compiler.RC2.Loop) -- reused here as the
-- first real test that MutualLoop now merges and converts them.

%default covering

-- Same shape as Test9SelfTailLoop.idr's isEvenM/isOddM, but run deep
-- enough (well beyond ordinary C stack recursion limits) that a
-- correct merge+goto conversion is the only way this doesn't crash.
isEvenM : Nat -> Bool
isOddM : Nat -> Bool
isEvenM Z = True
isEvenM (S k) = isOddM k
isOddM Z = False
isOddM (S k) = isEvenM k

-- Differing arities within one group (exercises slot padding): stepA
-- carries an extra Int argument stepB doesn't have. stepB also
-- sometimes tail-calls itself, not just stepA (exercises a same-tag
-- transition through the merged dispatch, not just cross-member).
stepA : Nat -> Int -> Int -> Int
stepB : Nat -> Int -> Int

stepA Z acc _ = acc
stepA (S k) acc extra = stepB k (acc + extra)

stepB Z acc = acc
stepB (S k) acc =
  if (acc `mod` 2) == 0
     then stepA k acc 3
     else stepB k (acc + 1)

-- 3-way cycle (exercises Tarjan's SCC beyond the trivial pairwise
-- case, and non-zero/non-one tag dispatch).
cycleA : Nat -> Nat -> Nat
cycleB : Nat -> Nat -> Nat
cycleC : Nat -> Nat -> Nat

cycleA Z acc = acc
cycleA (S k) acc = cycleB k (acc + 1)
cycleB Z acc = acc
cycleB (S k) acc = cycleC k (acc + 10)
cycleC Z acc = acc
cycleC (S k) acc = cycleA k (acc + 100)

main : IO ()
main = do
  printLn (isEvenM 500000)
  printLn (isOddM 500000)
  printLn (isEvenM 500001)
  -- Direct, non-tail calls from main, and use as a first-class
  -- closure value -- both must still behave as ordinary,
  -- independently-callable functions (the thin wrapper).
  printLn (isEvenM 4)
  printLn (map isEvenM [0, 1, 2, 3, 4, 5])
  --
  printLn (stepA 10 0 3)
  printLn (stepB 10 0)
  printLn (stepA 37 0 3)
  --
  printLn (cycleA 10 0)
  printLn (cycleB 10 0)
  printLn (cycleC 10 0)
  printLn (cycleA 300000 0)
