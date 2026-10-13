module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in ExportGCPtrReturn.err (checked by
-- ../check.sh); never imported by Test118FFI.

import System.FFI

%export "C:bad_export_gcptr"
wrap : Int -> GCAnyPtr
wrap _ = believe_me ()

main : IO ()
main = putStrLn "unreachable"
