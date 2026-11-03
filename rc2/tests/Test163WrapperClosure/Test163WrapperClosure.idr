module Main

import Data.IORef
import System

-- `step` takes the world as one more argument once `ArityRaise` has split it,
-- and what is left under its own name builds a closure over the raised function.
-- A closure over that wrapper, one argument supplied, is a closure over the raised
-- function (`doc/const-closure-fold.md`, "Closures over a bare wrapper").

%noinline
step : IORef Int -> Int -> Int -> IO ()
step r k n = modifyIORef r (+ (k * n))

%noinline
steps : IORef Int -> Int -> List (Int -> IO ())
steps r k = [step r k, step r (k + 1)]

%noinline
later : List (IORef Int -> Int -> Int -> IO ())
later = [step, \r, k, n => step r (k * 2) n]

%noinline
runWith : (IORef Int -> Int -> Int -> IO ()) -> IORef Int -> IO ()
runWith f r = f r 3 4

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  r <- newIORef 0
  traverse_ (\f => f 10) (steps r k)
  traverse_ (\f => f r k 100) later
  runWith step r
  printLn !(readIORef r)
