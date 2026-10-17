module Main

import Data.IORef

-- World arity raising must not raise a function that already took the world as
-- a parameter and returns an IO action as its *result*
-- (rc2/doc/world-arity-raising.md, "Soundness").
--
-- `start` calls an operation that gets a callback and returns how to give it
-- up. The operation runs the callback at once and returns the constant
-- `noCancel`, a closure waiting for one more argument. Before the fix its
-- lifted function `\env, done, world => ...` was raised once more, which moved
-- the call of `done` into the (unused) result closure: the callback never ran.

-- One constructor, one field: Idris2 compiles it to the IO action itself.
data Cancel = MkCancel (IO ())

noCancel : Cancel
noCancel = MkCancel (pure ())

runCancel : Cancel -> IO ()
runCancel (MkCancel act) = act

data Env = MkEnv Nat

data Op : Type -> Type where
  Async : (Env -> (a -> IO ()) -> IO Cancel) -> Op a

record Sched where
  constructor MkSched
  queue : IORef (List (IO ()))
  pending : IORef Nat

start : Sched -> Op a -> (a -> IO ()) -> IO ()
start s (Async f) k = do
  fired <- newIORef False
  modifyIORef s.pending S
  let complete = \x => do
        already <- readIORef fired
        unless already $ do
          writeIORef fired True
          modifyIORef s.pending (`minus` 1)
          modifyIORef s.queue (k x ::)
  giveUp <- f (MkEnv 0) complete
  already <- readIORef fired
  unless already $ modifyIORef s.queue (runCancel giveUp ::)

notify : (Nat -> IO ()) -> IO ()
notify d = d 2

check : String -> Op Nat -> Nat -> IO ()
check name op expected = do
  s <- [| MkSched (newIORef []) (newIORef 0) |]
  res <- newIORef (the Nat 0)
  start s op (\n => writeIORef res n)
  xs <- readIORef s.queue
  sequence_ xs
  n <- readIORef res
  p <- readIORef s.pending
  putStrLn (name ++ ": result " ++ show n ++ ", pending " ++ show p
            ++ (if n == expected && p == 0 then " ok" else " WRONG"))

main : IO ()
main = do
  -- the callback called in the lambda
  check "direct" (Async (\env, done => do { done 1; pure noCancel })) 1
  -- through a named function that takes the world
  check "named call" (Async (\env, done => do { notify done; pure noCancel })) 2
  -- the action kept in a local and run later
  check "local action" (Async (\env, done => do
                                 let act = done 3
                                 act
                                 pure noCancel)) 3
  -- an operation that does not finish: its cancel is handed back and run
  s <- [| MkSched (newIORef []) (newIORef 0) |]
  cancelled <- newIORef False
  start s (the (Op Nat) (Async (\env, done => pure (MkCancel (writeIORef cancelled True))))) (\n => pure ())
  xs <- readIORef s.queue
  sequence_ xs
  c <- readIORef cancelled
  putStrLn ("cancel handed back: " ++ show c)
