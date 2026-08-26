module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for the remaining untested pieces of idris_support.c (a
-- libidris2_support.a fallback rc2 has no native port of): getEnv,
-- getPID, sleep/usleep (just confirm they return without hanging/
-- crashing, never assert on timing), and System.Info's
-- getNProcessors. getStr/enableRawMode/resetRawMode are deliberately
-- not covered here -- they need a real stdin/tty, not available in an
-- automated run.
--
-- setEnv/unsetEnv are ALSO deliberately not covered: idris_support.h
-- (upstream, read-only reference) declares no prototype at all for
-- idris2_setenv/idris2_unsetenv, even though idris_support.c actually
-- defines both and System.idr's own %foreign declarations target them
-- through that same header -- a real upstream header/implementation
-- mismatch. Harmless under real `idris2 --cg refc` (plain gcc warns,
-- doesn't fail, on an implicit declaration by default) but a hard
-- compile error under rc2's own `-Werror` build policy. Not rc2's bug
-- to fix (idris_support.c isn't a native rc2 port, unlike Data.Buffer/
-- System.Clock/network's idrnet_*), and out of this test's own scope
-- to work around.

import System
import System.Info

envVar : String
envVar = "RC2_TEST42_VAR"

main : IO ()
main = do
  envResult <- getEnv envVar
  putStrLn ("getEnv (arbitrary unset var): " ++ show envResult)

  pid <- getPID
  putStrLn ("getPID positive: " ++ show (pid > 0))

  sleep 0
  usleep 1000
  putStrLn "sleep/usleep: ok"

  Just n <- getNProcessors
    | Nothing => putStrLn "getNProcessors: Nothing"
  putStrLn ("getNProcessors positive: " ++ show (n > 0))

  putStrLn "done"
