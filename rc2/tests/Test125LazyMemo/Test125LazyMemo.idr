module Main

-- `Lazy` and `Inf` values are evaluated at most once per cell
-- (rc2/doc/lazy-memoization.md). Every delayed value here is built at run
-- time from a parameter, so none can be folded into a constant.

import Data.IORef
import Data.Stream
import System.Concurrency.RC2

-- Counts its own evaluations in `ref`.
counted : IORef Int -> Int -> Lazy Int
counted ref x = delay (unsafePerformIO (do modifyIORef ref (+ 1); pure (x * 2)))

twice : Lazy Int -> Int
twice v = force v + force v

-- Each tail counts its own evaluation. `take 5` forces five tails: the
-- last call still forces its argument at the call site.
countedFrom : IORef Int -> Nat -> Stream Nat
countedFrom ref n = n :: unsafePerformIO (do modifyIORef ref (+ 1); pure (countedFrom ref (S n)))

lazyFn : Int -> Lazy (Int -> Int)
lazyFn k = delay (\x => x + k)

main : IO ()
main = do
  ref <- newIORef 0
  let v = counted ref 21
  printLn (twice v)
  readIORef ref >>= \n => putStrLn "Lazy evaluations: \{show n}"

  sref <- newIORef 0
  let s = countedFrom sref 0
  printLn (take 5 s)
  printLn (take 5 s)
  readIORef sref >>= \n => putStrLn "Inf tail evaluations: \{show n}"

  let f = lazyFn 10
  printLn (force f 1 + force f 2)

  -- Freeing a long forced stream loops in the runtime's teardown rather
  -- than recursing once per element.
  let long = iterate (+ 1) (the Integer 0)
  printLn (index 999999 long)
  printLn (index 0 long)

  tref <- newIORef 0
  let shared = counted tref 50
  hs <- traverse (\_ => forkJoin (pure (force shared))) [1, 2, 3, 4]
  rs <- traverse join hs
  printLn rs
