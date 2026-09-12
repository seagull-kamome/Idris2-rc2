module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for RMemoize (rc2/doc/caf-memoization.md): a plain
-- top-level unsafePerformIO CAF used to compile to an ordinary
-- 0-argument C function, re-run (and re-allocating its own IORef) on
-- every reference -- three independent counters instead of one shared
-- one (TODO.md's own former "Semantics: a plain unsafePerformIO CAF
-- isn't memoized either" entry: `0 0 0`, confirmed identically on both
-- --cg rc2 and upstream --cg refc before this fix). Expects `0 1 2`,
-- the same result --cg chez already gave.

import Data.IORef

counter : IORef Int
counter = unsafePerformIO (newIORef 0)

bump : IO Int
bump = do
  n <- readIORef counter
  writeIORef counter (n + 1)
  pure n

main : IO ()
main = do
  a <- bump
  b <- bump
  c <- bump
  printLn a
  printLn b
  printLn c
