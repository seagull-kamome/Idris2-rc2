module Main

-- Exercises Compiler.RC2.Loop's self-tail-call -> goto conversion:
-- parameter swapping (aliasing hazard for the simultaneous-assignment
-- temp-snapshot), multiple recursive branches in one function, a
-- self-tail-call whose argument is passed straight through unchanged
-- (a "move", not a recompute), and confirms mutual recursion (which is
-- explicitly out of scope) still works correctly via the ordinary
-- boxed trampoline. Also covers Compiler.RC2.MutualLoop's own
-- merge-and-goto conversion for groups of >= 2 mutually tail-recursive
-- functions (formerly a separate Test10MutualLoop.idr, merged in
-- below): this file's own isEvenM/isOddM are reused as-is for that
-- pass's own regression check (run far deeper than the boxed-
-- trampoline checks above, well beyond ordinary C stack recursion
-- limits, confirming MutualLoop's merge+goto conversion is what
-- actually makes that not crash), plus `stepA`/`stepB` (differing
-- arities within one mutual group) and a 3-way `cycleA`/`cycleB`/
-- `cycleC` cycle (Tarjan's SCC beyond the trivial pairwise case).

%default covering

-- Parameter swap: if the simultaneous-assignment snapshot were done
-- naively (sequential var_0 = var_1; var_1 = var_0;) this would corrupt
-- the second parameter. Counts down `steps`, swapping (a,b) each time.
swapLoop : Nat -> Int -> Int -> (Int, Int)
swapLoop Z a b = (a, b)
swapLoop (S k) a b = swapLoop k b a

-- Multiple distinct self-tail-call sites in one function (three
-- separate branches all recursing differently), plus a genuine base
-- case (no self-call at all).
data Step = Forward | Backward | Skip Nat

collatzLike : Nat -> Int -> Int
collatzLike Z acc = acc
collatzLike (S k) acc =
  if acc == 0 then acc
  else if (acc `mod` 2) == 0 then collatzLike k (acc `div` 2)
  else collatzLike k ((acc * 3) + 1)

-- Argument passed straight through unchanged (a "move", not a
-- recompute) -- exercises the case where annotate treats it as
-- ownership-transfer rather than a fresh dup.
countDown : Int -> String -> String
countDown 0 msg = msg
countDown n msg = countDown (n - 1) msg

-- Mutual recursion: explicitly out of scope for Compiler.RC2.Loop
-- (TODO.md), must still work correctly via the ordinary boxed
-- trampoline (not converted to a goto loop). Also the pair
-- Compiler.RC2.MutualLoop's own merge-and-goto conversion is
-- regression-checked against below, at far greater recursion depth.
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
  printLn (swapLoop 0 1 2)
  printLn (swapLoop 1 1 2)
  printLn (swapLoop 2 1 2)
  printLn (swapLoop 7 1 2)
  printLn (swapLoop 100000 1 2)
  --
  printLn (collatzLike 100 27)
  printLn (collatzLike 5 8)
  printLn (collatzLike 0 999)
  --
  printLn (countDown 5 "done")
  printLn (countDown 500000 "done")
  --
  printLn (isEvenM 10000)
  printLn (isOddM 10000)
  printLn (isEvenM 10001)
  -- absorbed from former Test10MutualLoop: MutualLoop's own
  -- merge-and-goto conversion, run far deeper than the boxed-
  -- trampoline checks above.
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
