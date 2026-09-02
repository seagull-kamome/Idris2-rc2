module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Sizeof: checks every one of its
-- eleven `Sizeof` instances (matching System.FFI.C.Ptr's own element
-- type set) reports its expected C `sizeof`.

import System.FFI.C.Sizeof

main : IO ()
main = do
  printLn (sizeof Bits8)
  printLn (sizeof Bits16)
  printLn (sizeof Bits32)
  printLn (sizeof Bits64)
  printLn (sizeof Int8)
  printLn (sizeof Int16)
  printLn (sizeof Int32)
  printLn (sizeof Int64)
  printLn (sizeof Int)
  printLn (sizeof Double)
  printLn (sizeof AnyPtr)
