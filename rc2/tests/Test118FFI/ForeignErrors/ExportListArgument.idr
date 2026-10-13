module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in ExportListArgument.err (checked by
-- ../check.sh); never imported by Test118FFI.

%export "C:bad_export_list"
sumAll : List Int -> Int
sumAll = sum

main : IO ()
main = printLn (sumAll [1, 2, 3])
