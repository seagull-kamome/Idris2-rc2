module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for the runtime lifecycle hooks (support/rc2/runtime.c:
-- idris2rc2_rtInit / idris2rc2_rtFinish), which Compiler.RC2.Emit's
-- generated main() now calls around the entry point.
--
-- rtInit runs `setlocale(LC_ALL, "")` so a UTF-8 environment locale
-- reaches libc -- Text.Regex.POSIX's `.` / character classes need a
-- UTF-8 LC_CTYPE to operate on codepoints instead of bytes -- then
-- `setlocale(LC_NUMERIC, "C")` so numeric.c's "%f" Double formatting
-- stays locale-independent.
--
-- verify.sh runs the whole suite under LC_ALL=C.UTF-8, so after rtInit
-- the process locale is "C.UTF-8" for LC_CTYPE and "C" for LC_NUMERIC.
-- A companion C file (Test82RuntimeLocale.c) reads both back. The
-- Double line locks the "%f" output shape.
--
-- In verify.sh's NO_REFC_DIFF_TESTS: real RefC's own main() has no
-- equivalent setlocale call, so there is no shared baseline to diff
-- against.

%foreign "C:idris2rc2_test82_ctype,libc,Test82RuntimeLocale.h"
prim__ctype : PrimIO String

%foreign "C:idris2rc2_test82_numeric,libc,Test82RuntimeLocale.h"
prim__numeric : PrimIO String

pi100 : Double
pi100 = 3.14

main : IO ()
main = do
  ct <- primIO prim__ctype
  nm <- primIO prim__numeric
  putStrLn ("LC_CTYPE: " ++ ct)
  putStrLn ("LC_NUMERIC: " ++ nm)
  putStrLn ("double: " ++ show pi100)
  putStrLn "done"
