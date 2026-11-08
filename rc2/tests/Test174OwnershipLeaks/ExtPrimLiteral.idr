module Test174OwnershipLeaks.ExtPrimLiteral

import Data.IORef
import Data.IOArray
import System

-- A native operand of an external primitive (`newIORef`, `writeIORef`,
-- `newArray`, `writeArray`) is boxed for the call and the box is dropped after
-- it: a `Double` or a large `Int` literal, and a native `Double` local, must not
-- leak one cell per call. valgrind checks it; see `doc/c-struct-support.md`.

%noinline
bumpLiteral : IORef Double -> Int -> IO ()
bumpLiteral r 0 = pure ()
bumpLiteral r n = writeIORef r 1.5 >> bumpLiteral r (n - 1)

%noinline
bumpBig : IORef Int -> Int -> IO ()
bumpBig r 0 = pure ()
bumpBig r n = writeIORef r 9223372036854775807 >> bumpBig r (n - 1)

%noinline
bumpLocal : IORef Double -> Double -> Int -> IO ()
bumpLocal r d 0 = pure ()
bumpLocal r d n = writeIORef r (d * 2.0) >> bumpLocal r (d + 1.0) (n - 1)

%noinline
fillArray : IOArray Double -> Int -> IO ()
fillArray a 0 = pure ()
fillArray a n = do
  _ <- writeArray a (n `mod` 4) 2.25
  fillArray a (n - 1)

export
run : IO ()
run = do
  args <- getArgs
  let k = cast {to = Int} (length args) + 999
  r <- newIORef 0.0
  bumpLiteral r k
  printLn (cast {to = Int} (!(readIORef r) * 100.0))
  big <- newIORef 0
  bumpBig big k
  printLn !(readIORef big)
  loc <- newIORef 0.0
  bumpLocal loc 1.0 k
  printLn (cast {to = Int} !(readIORef loc))
  arr <- the (IO (IOArray Double)) (newArray 4)
  fillArray arr k
  Just v <- readArray arr 0
    | Nothing => putStrLn "empty"
  printLn (cast {to = Int} (v * 100.0))
