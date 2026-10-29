module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Functions generic over `HasIO`/`Monad` that were specialised to `IO` called
-- the lifted `Monad IO` bind with two freshly built closures per call. The
-- early inline splices a callee of a few nodes at every call site and the
-- bind's `apply`s of those closures become direct calls (rc2/doc/inlining.md,
-- "Criterion C: tiny callees"). check.sh looks at the IR; the output must be
-- right either way, and valgrind (LEAK_SENSITIVE_TESTS) sees no leak.

import Data.IORef
import Data.List
import System

countTo : IORef Int -> Int -> IO ()
countTo r 0 = pure ()
countTo r n = do
  modifyIORef r (+ 1)
  countTo r (n - 1)

swapAdd : IORef Int -> IORef Int -> Int -> IO ()
swapAdd a b 0 = pure ()
swapAdd a b n = do
  modifyIORef a (+ n)
  x <- readIORef a
  modifyIORef b (\y => y * 2 + x `mod` 7)
  swapAdd a b (n - 1)

main : IO ()
main = do
  args <- getArgs
  let k : Int = case args of { (_ :: a :: _) => cast a; _ => 1000 }
  r <- newIORef 0
  countTo r k
  readIORef r >>= printLn
  a <- newIORef 0
  b <- newIORef 1
  swapAdd a b 30
  readIORef a >>= printLn
  readIORef b >>= printLn
