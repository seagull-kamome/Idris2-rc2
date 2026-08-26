module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System's system/run (idris_system.c's idris2_system,
-- plus idris_file.c's popen/pclose via System.File.Process -- both
-- libidris2_support.a fallbacks rc2 has no native port of): system
-- runs a command and reports its exit code, run captures stdout too.

import System

main : IO ()
main = do
  trueCode <- System.system "true"
  putStrLn ("system true exit code: " ++ show trueCode)

  falseCode <- System.system "false"
  putStrLn ("system false exit code: " ++ show falseCode)

  (out, code) <- System.run "echo hello-rc2"
  putStrLn ("run output: " ++ show out)
  putStrLn ("run exit code: " ++ show code)

  putStrLn "done"
