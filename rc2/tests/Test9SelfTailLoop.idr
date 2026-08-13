module Main

-- Exercises Compiler.RC2.Loop's self-tail-call -> goto conversion:
-- parameter swapping (aliasing hazard for the simultaneous-assignment
-- temp-snapshot), multiple recursive branches in one function, a
-- self-tail-call whose argument is passed straight through unchanged
-- (a "move", not a recompute), and confirms mutual recursion (which is
-- explicitly out of scope) still works correctly via the ordinary
-- boxed trampoline.

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
-- trampoline (not converted to a goto loop).
isEvenM : Nat -> Bool
isOddM : Nat -> Bool
isEvenM Z = True
isEvenM (S k) = isOddM k
isOddM Z = False
isOddM (S k) = isEvenM k

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
