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
--
-- Also covers `Integer` (`CFInteger`) as a `%foreign` RETURN type
-- (formerly a separate Test55FFIIntegerReturn.idr, merged in below):
-- such a declaration now compiles to a call with an extra, implicit
-- *leading* `mpz_t` out-parameter (a freshly allocated
-- `IDRIS2RC2_Integer`'s own embedded state) rather than assigning from
-- a nonexistent C-level return value -- matching every real GMP API's
-- own out-parameter convention exactly, `rop` always first
-- (`mpz_add(rop, op1, op2)`, `mpz_set_str(rop, str, base)`, etc. --
-- none of them return one), so a declaration can bind directly to a
-- real GMP function's own signature with no wrapper of its own needed.
-- `Compiler.RC2.Emit` has two independent call-emission paths that
-- both needed this (`emitGenericForeignWrapper`'s own hand-rolled
-- logic for the always-Boxed wrapper, and `ffiRawCall`, shared by
-- `Compiler.RC2.DualABI`'s Stage 5 inline splice) -- exercised here via
-- two declarations, one all-Boxed (never DualABI-eligible, so only
-- ever compiled through `emitGenericForeignWrapper`) and one with a
-- native `Int` argument alongside the `Integer` one (DualABI-eligible,
-- so its own non-tail call sites below go through the inline path
-- instead) -- each in both a plain and a `PrimIO`-wrapped form, to
-- cover both of `Emit.idr`'s own new `CFInteger`/`CFIORes CFInteger`
-- branches in each path. Reuses this file's own `bigValue` above
-- (well outside `Int`'s 64-bit range) rather than redefining an
-- identical constant.

%foreign "C:idris2rc2_test54_toDecimalString,libc,Test54FFIInteger.h"
prim__integerToDecimal : Integer -> String

%foreign "C:idris2rc2_test55_fromDecimalString,libc,Test54FFIInteger.h"
prim__integerFromString : String -> Integer

%foreign "C:idris2rc2_test55_fromDecimalStringIO,libc,Test54FFIInteger.h"
prim__integerFromStringIO : String -> PrimIO Integer

%foreign "C:idris2rc2_test55_addInt,libc,Test54FFIInteger.h"
prim__integerAddInt : Integer -> Int -> Integer

%foreign "C:idris2rc2_test55_addIntIO,libc,Test54FFIInteger.h"
prim__integerAddIntIO : Integer -> Int -> PrimIO Integer

bigValue : Integer
bigValue = 123456789012345678901234567890

main : IO ()
main = do
    printLn (prim__integerToDecimal bigValue == show bigValue)
    printLn (prim__integerToDecimal (negate bigValue) == show (negate bigValue))
    putStrLn (prim__integerToDecimal bigValue)
    -- absorbed from former Test55FFIIntegerReturn
    printLn (prim__integerFromString "123456789012345678901234567890" == bigValue)
    fromStringIO <- primIO (prim__integerFromStringIO "123456789012345678901234567890")
    printLn (fromStringIO == bigValue)

    printLn (prim__integerAddInt bigValue 42 == bigValue + 42)
    addIntIO <- primIO (prim__integerAddIntIO bigValue 42)
    printLn (addIntIO == bigValue + 42)
