module Main

-- Reference counting stays plain until the program starts a thread
-- (rc2/doc/hybrid-refcount.md): `fork` switches it to atomic first.

import Data.IORef
import System.Concurrency
import System.Concurrency.RC2
import System.GC.RC2

main : IO ()
main = do
  before <- isMultiThreaded
  putStrLn "before fork: \{show before}"
  lock <- makeMutex
  cond <- makeCondition
  done <- newIORef False
  _ <- fork $ do
    mutexAcquire lock
    writeIORef done True
    conditionSignal cond
    mutexRelease lock
  mutexAcquire lock
  waitDone lock cond done
  mutexRelease lock
  after <- isMultiThreaded
  putStrLn "after fork: \{show after}"
  where
    waitDone : Mutex -> Condition -> IORef Bool -> IO ()
    waitDone lock cond done = do
      d <- readIORef done
      if d then pure () else conditionWait cond lock >> waitDone lock cond done
