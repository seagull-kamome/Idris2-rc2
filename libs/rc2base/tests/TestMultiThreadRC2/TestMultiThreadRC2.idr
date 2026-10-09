module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.GC.RC2's switch to atomic reference counting
-- (rc2/doc/hybrid-refcount.md): off at start, on for good once
-- enabled, and threads started afterwards still share values safely.

import System.Concurrency.RC2
import System.GC.RC2

main : IO ()
main = do
  before <- isMultiThreaded
  putStrLn "at start: \{show before}"
  enableMultiThreading
  after <- isMultiThreaded
  putStrLn "after enableMultiThreading: \{show after}"
  let xs = [1 .. 1000]
  h <- forkJoin (pure (sum xs))
  r <- join h
  putStrLn "sum on another thread: \{show r}, here: \{show (sum xs)}"
