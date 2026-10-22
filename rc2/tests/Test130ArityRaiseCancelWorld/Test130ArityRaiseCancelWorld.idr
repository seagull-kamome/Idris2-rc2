module Main

import Data.Maybe

import Data.IORef

-- The cancel action of an `Async`-style starter is an external primitive
-- (`writeIORef`) applied to everything but the world. The starter must not run
-- it when it is called: the cancel is only handed back.

data Cancel = MkCancel (IO ())

runCancel : Cancel -> IO ()
runCancel (MkCancel act) = act

data Op : Type where
  Async : ((Nat -> IO ()) -> IO Cancel) -> Op

hold : IORef (Maybe (Nat -> IO ())) -> Op
hold r = Async (\done => do
  writeIORef r (Just done)
  pure (MkCancel (writeIORef r Nothing)))

start : Op -> IO Cancel
start (Async f) = f (\_ => pure ())

main : IO ()
main = do
  r1 <- newIORef (the (Maybe (Nat -> IO ())) Nothing)
  r2 <- newIORef (the (Maybe (Nat -> IO ())) Nothing)
  c1 <- start (hold r1)
  c2 <- start (hold r2)
  m1 <- readIORef r1
  m2 <- readIORef r2
  putStrLn ("registered: " ++ show (isJust m1) ++ " " ++ show (isJust m2))
  runCancel c1
  runCancel c2
  m1 <- readIORef r1
  m2 <- readIORef r2
  putStrLn ("withdrawn: " ++ show (isNothing m1) ++ " " ++ show (isNothing m2))
