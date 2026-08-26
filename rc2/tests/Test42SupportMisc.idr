module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for the remaining untested pieces of idris_support.c (a
-- libidris2_support.a fallback rc2 has no native port of): getEnv/
-- setEnv/unsetEnv, getPID, sleep/usleep (just confirm they return
-- without hanging/crashing, never assert on timing), and System.Info's
-- getNProcessors. getStr/enableRawMode/resetRawMode are deliberately
-- not covered here -- they need a real stdin/tty, not available in an
-- automated run.
--
-- setEnv/unsetEnv needed idris2rc2_runtime.h to declare their own
-- prototypes ahead of upstream's idris_support.h (which has none, a
-- real upstream header/implementation mismatch -- see that file's own
-- comment) before this test could even compile under rc2's `-Werror`
-- policy.

import System
import System.Info

envVar : String
envVar = "RC2_TEST42_VAR"

main : IO ()
main = do
  envResult <- getEnv envVar
  putStrLn ("getEnv (arbitrary unset var): " ++ show envResult)

  True <- setEnv envVar "hello" True
    | False => putStrLn "setEnv: FAILED"
  afterSet <- getEnv envVar
  putStrLn ("getEnv (after setEnv): " ++ show afterSet)

  True <- unsetEnv envVar
    | False => putStrLn "unsetEnv: FAILED"
  afterUnset <- getEnv envVar
  putStrLn ("getEnv (after unsetEnv): " ++ show afterUnset)

  pid <- getPID
  putStrLn ("getPID positive: " ++ show (pid > 0))

  sleep 0
  usleep 1000
  putStrLn "sleep/usleep: ok"

  Just n <- getNProcessors
    | Nothing => putStrLn "getNProcessors: Nothing"
  putStrLn ("getNProcessors positive: " ++ show (n > 0))

  putStrLn "done"
