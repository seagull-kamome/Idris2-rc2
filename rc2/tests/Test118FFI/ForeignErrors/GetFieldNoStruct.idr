module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in GetFieldNoStruct.err (checked by
-- ../check.sh); never imported by Test118FFI.

import System.FFI

-- "ghost" appears in no %foreign signature.
Ghost : Type
Ghost = Struct "ghost" [("x", Int)]

peek : Ghost -> Int
peek g = getField g "x"

main : IO ()
main = printLn (peek (believe_me ()))
