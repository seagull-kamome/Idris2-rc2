module Main

import Data.IORef
import System

-- A function that only forwards its parameters to another is an alias
-- (`Compiler.RC2.FwdAlias`, `doc/fwd-alias.md`): `withLog` is `step` applied to
-- its own parameters once the IO world is raised, and `table` holds it as a
-- closure, and `withLog2` forwards to `withLog`. `check.sh` counts the
-- forwarders in the IR.

%noinline
step : IORef Int -> Int -> Int -> IO ()
step r k n = modifyIORef r (+ (k * n))

%noinline
withLog : IORef Int -> Int -> Int -> IO ()
withLog r k n = step r k n

%noinline
withLog2 : IORef Int -> Int -> Int -> IO ()
withLog2 r k n = withLog r k n

%noinline
table : List (IORef Int -> Int -> Int -> IO ())
table = [withLog, withLog2, step]

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  r <- newIORef 0
  traverse_ (\f => f r k 3) table
  withLog r (k + 1) 5
  printLn !(readIORef r)
