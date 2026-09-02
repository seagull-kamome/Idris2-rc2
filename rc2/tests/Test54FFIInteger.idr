module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for TODO.md's "`Integer` (`CFInteger`) has no
-- `%foreign` codegen support at all": a `%foreign` declaration with an
-- `Integer` argument used to crash rc2's own codegen outright
-- ("INTERNAL ERROR: Unknown FFI type in rc2 backend: Integer").
-- `Compiler.RC2.EmitUtil`'s `extractValue` now hands a real GMP
-- function `IDRIS2RC2_Integer`'s own embedded `mpz_t` directly (no
-- copy, no truncation) -- confirmed here with values well outside
-- `Int`'s 64-bit range, both positive and negative, by round-tripping
-- through a real `mpz_get_str` on the C side and comparing against
-- Idris's own `show` of the exact same value.

%foreign "C:idris2rc2_test54_toDecimalString,libc,Test54FFIInteger.h"
prim__integerToDecimal : Integer -> String

bigValue : Integer
bigValue = 123456789012345678901234567890

main : IO ()
main = do
    printLn (prim__integerToDecimal bigValue == show bigValue)
    printLn (prim__integerToDecimal (negate bigValue) == show (negate bigValue))
    putStrLn (prim__integerToDecimal bigValue)
