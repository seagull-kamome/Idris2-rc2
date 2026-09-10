module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for the runtime lifecycle hooks (support/rc2/runtime.c:
-- idris2rc2_rtInit / idris2rc2_rtFinish), which Compiler.RC2.Emit's
-- generated main() now calls around the entry point.
--
-- rtInit runs `setlocale(LC_ALL, "")` so a UTF-8 environment locale
-- reaches libc -- Text.Regex.POSIX's `.` / character classes need a
-- UTF-8 LC_CTYPE to operate on codepoints instead of bytes. verify.sh
-- runs the suite under LC_ALL=C.UTF-8, so a companion C file reads the
-- process's LC_CTYPE back and it must be "C.UTF-8".
--
-- Number formatting deliberately does NOT depend on the locale:
-- numeric.c carries its own '.'-based Double<->String conversion, so
-- `show`/`cast` stay stable in every environment (the `3.14` line).
--
-- In verify.sh's NO_REFC_DIFF_TESTS: real RefC's own main() has no
-- equivalent setlocale call.

%foreign "C:idris2rc2_test82_ctype,libc,Test82RuntimeLocale.h"
prim__ctype : PrimIO String

pi3 : Double
pi3 = 3.14

main : IO ()
main = do
  ct <- primIO prim__ctype
  putStrLn ("LC_CTYPE: " ++ ct)
  putStrLn ("double: " ++ show pi3)
  putStrLn "done"
