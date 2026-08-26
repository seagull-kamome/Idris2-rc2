module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.EmitUtil's cTypeOfCFType CFString
-- case: a CFString-returning %foreign wrapper is now declared as
-- `const char *`, not plain `char *` -- so binding a real C function
-- that genuinely returns `const char *` (e.g. curl_easy_strerror's own
-- shape) no longer collides with this project's own -Werror policy
-- (-Wdiscarded-qualifiers would otherwise turn "returning 'const char
-- *' from a function with return type 'char *' discards qualifiers"
-- into a hard build failure). See TODO.md's git history / KNOWN-BUGS.md
-- for the original finding.

%foreign "C:idris2rc2_test47_greeting,libc,Test47ConstCFStringReturn.h"
prim__test47Greeting : PrimIO String

main : IO ()
main = do
  s <- primIO prim__test47Greeting
  putStrLn s
