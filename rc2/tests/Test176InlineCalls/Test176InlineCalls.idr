module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System
import Test176InlineCalls.InlineWithCalls

main : IO ()
main = do
  args <- getArgs
  run (cast (length args) + 4)
