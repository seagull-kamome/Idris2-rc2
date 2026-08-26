module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System.Term (idris_term.c, a libidris2_support.a
-- fallback rc2 has no native port of): getTermCols/getTermLines. Per
-- System.Term's own doc comment, both return 0 (not an error) when
-- stdout isn't a real TTY -- true for every automated test run here --
-- so this only asserts non-negativity, never a specific terminal size,
-- to stay deterministic across environments.

import System.Term

main : IO ()
main = do
  setupTerm
  cols <- getTermCols
  lines <- getTermLines
  putStrLn ("cols non-negative: " ++ show (cols >= 0))
  putStrLn ("lines non-negative: " ++ show (lines >= 0))
  putStrLn "done"
