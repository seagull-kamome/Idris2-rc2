module Main

-- A thread's stack (rc2/doc/concurrency.md, "Thread stacks"). A
-- recursion that is not a tail call runs on a `fork`ed thread and on a
-- `forkJoin` thread, and each result comes back to the main thread.
--
--   Test193ThreadStack          depth 20,000, which fits any stack
--   Test193ThreadStack DEPTH    that depth
--   Test193ThreadStack size     the two threads' stack sizes in bytes
--   Test193ThreadStack set V    the same, after setting IDRIS2RC2_THREAD_STACK
--                               to V itself
--
-- verify.sh runs the first form. check.sh runs the others with the
-- stack limits and IDRIS2RC2_THREAD_STACK values the runtime's choice
-- shows under.

import Data.IORef
import Data.Maybe
import Data.String
import System
import System.Concurrency
import System.Concurrency.RC2

%foreign "C:idris2rc2_test193_stackSize,libc,Test193ThreadStack.h"
prim__stackSize : PrimIO Int

-- `Integer`, so every level is a call into the runtime the C compiler
-- cannot turn into a loop: one C frame per level.
sumTo : Integer -> Integer
sumTo 0 = 0
sumTo n = n + sumTo (n - 1)

-- The depth is read on the thread, so the recursion cannot run before
-- the thread starts.
deep : IORef Integer -> IO Integer
deep ref = do
  n <- readIORef ref
  pure (sumTo n)

onBoth : Show a => IO a -> IO ()
onBoth act = do
  ch <- makeChannel
  _ <- fork (act >>= channelPut ch)
  r <- channelGet ch
  putStrLn "fork: \{show r}"
  h <- forkJoin act
  r' <- join h
  putStrLn "forkJoin: \{show r'}"

main : IO ()
main = do
  args <- getArgs
  case args of
    [_, "size"] => onBoth (primIO prim__stackSize)
    [_, "set", v] => do
      _ <- setEnv "IDRIS2RC2_THREAD_STACK" v True
      onBoth (primIO prim__stackSize)
    [_, d] => do
      ref <- newIORef (fromMaybe 0 (parsePositive d))
      onBoth (deep ref)
    _ => do
      ref <- newIORef 20000
      onBoth (deep ref)
