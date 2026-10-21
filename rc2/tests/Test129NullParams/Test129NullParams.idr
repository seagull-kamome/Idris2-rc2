module Main

import Data.IORef
import Data.List

-- Parameters that only ever hold the world or an erased value get a native
-- NULL type in the worker (rc2/doc/null-params.md). The cases:
--
-- * a world reaching a `%foreign` slot through a chain of IO functions;
-- * a world held in a partial application and applied later;
-- * an erased argument every caller passes;
-- * IO loops, which keep the world in a loop slot, one of them a state
--   machine that shares a slot between states.

%noinline
countdown : IORef Nat -> Nat -> IO ()
countdown ref Z = pure ()
countdown ref (S k) = do
  modifyIORef ref (+ 1)
  countdown ref k

%noinline
ping : IORef (List String) -> Nat -> IO ()
pong : IORef (List String) -> Nat -> IO ()

ping ref Z = modifyIORef ref ("ping done" ::)
ping ref (S k) = do
  modifyIORef ref ("ping" ::)
  pong ref k

pong ref Z = modifyIORef ref ("pong done" ::)
pong ref (S k) = do
  modifyIORef ref ("pong" ::)
  ping ref k

%noinline
logTo : IORef (List String) -> String -> IO ()
logTo ref s = modifyIORef ref (s ::)

%noinline
lengthOf : {0 a : Type} -> List a -> Nat -> Nat
lengthOf [] acc = acc
lengthOf (_ :: xs) acc = lengthOf xs (S acc)

%noinline
sizes : IO ()
sizes = do
  printLn (lengthOf [1, 2, 3] 0)
  printLn (lengthOf ["a", "b"] 10)
  printLn (lengthOf (the (List Bool) []) 7)

main : IO ()
main = do
  c <- newIORef (the Nat 0)
  countdown c 1000
  readIORef c >>= printLn
  l <- newIORef []
  ping l 5
  readIORef l >>= printLn . reverse
  let later = logTo l
  let again = later "partial"
  again
  again
  readIORef l >>= \xs => printLn (take 3 xs)
  sizes
