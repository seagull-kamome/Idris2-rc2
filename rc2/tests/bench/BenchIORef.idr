module Main

import Data.IORef

-- Reads and writes one IORef in a loop: the cost of its slot lock in a
-- single-threaded program (rc2/doc/hybrid-refcount.md).
loop : IORef Int -> Int -> IO ()
loop ref 0 = pure ()
loop ref n = do
  x <- readIORef ref
  writeIORef ref (x + n)
  loop ref (n - 1)

main : IO ()
main = do
  ref <- newIORef 0
  loop ref 100000000
  readIORef ref >>= printLn
