module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A program that imports Control.Task.Uring and runs Tasks, but never refers
-- to a request, must build and run without liburing: rc2 collects the headers
-- and libraries of the %foreign declarations that are still there after dead
-- code elimination, so nothing of liburing may be reachable from here.
-- tests/verify.sh also looks for "liburing" in the generated C of this test.

import Control.Task
import Control.Task.Scheduler
import Control.Task.Uring

main : IO ()
main = do
  r <- runTask (do sleepFor 1; pure (the Nat 7))
  putStrLn ("task: " ++ show r)
