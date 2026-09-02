module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Data.Integer.GMP: every one of its bindings
-- exercised at least once, cross-checked either against Idris's own
-- native `Integer` arithmetic (the same `mpz_t` state, computed
-- through a completely different code path -- rc2's own native
-- +/-/*/`mod`, not GMP called through `%foreign` at all) or against
-- known textbook constants, with values kept well outside `Int`'s
-- 64-bit range wherever the check itself doesn't specifically need a
-- small one (`fitsSlongP`, bit-position examples, etc).

import Data.Integer.GMP

big1 : Integer
big1 = 123456789012345678901234567890

big2 : Integer
big2 = 987654321098765432109876543210

main : IO ()
main = do
    -- Arithmetic
    printLn (GMP.add big1 big2 == big1 + big2)
    printLn (GMP.sub big2 big1 == big2 - big1)
    printLn (GMP.mul big1 big2 == big1 * big2)
    printLn (GMP.neg big1 == negate big1)
    printLn (GMP.abs (negate big1) == big1)
    printLn (GMP.addUi big1 42 == big1 + 42)
    printLn (GMP.subUi big1 42 == big1 - 42)
    printLn (GMP.uiSub 42 big1 == 42 - big1)
    printLn (GMP.mulSi big1 (-3) == big1 * (-3))
    printLn (GMP.mulUi big1 3 == big1 * 3)
    printLn (GMP.gcd 1071 462 == 21)
    printLn (GMP.lcm 4 6 == 12)

    -- Division family -- algebraic identity q*b + r == a, and mod's
    -- own always-non-negative-regardless-of-sign guarantee, checked
    -- directly against a negative dividend.
    let a : Integer
        a = negate big1
        b : Integer
        b = 7
    printLn (GMP.tdivQ a b * b + GMP.tdivR a b == a)
    printLn (GMP.fdivQ a b * b + GMP.fdivR a b == a)
    printLn (GMP.cdivQ a b * b + GMP.cdivR a b == a)
    printLn (GMP.mod a b >= 0 && GMP.mod a b < b)
    printLn (GMP.divexact (big1 * 7) 7 == big1)

    -- Power/root
    printLn (GMP.uiPowUi 2 10 == 1024)
    printLn (GMP.powUi 2 10 == 1024)
    printLn (GMP.powm 4 13 497 == 445)
    printLn (GMP.powmUi 4 13 497 == 445)
    printLn (GMP.sqrt (big1 * big1) == big1)

    -- Shifts -- cross-checked against the already-verified division
    -- family and plain multiplication, using a literal 2^10 = 1024
    -- rather than an independent exponentiation.
    printLn (GMP.mul2exp big1 10 == big1 * 1024)
    printLn (GMP.tdivQ2exp a 10 == GMP.tdivQ a 1024)
    printLn (GMP.tdivR2exp a 10 == GMP.tdivR a 1024)
    printLn (GMP.fdivQ2exp a 10 == GMP.fdivQ a 1024)
    printLn (GMP.fdivR2exp a 10 == GMP.fdivR a 1024)

    -- Bitwise
    printLn (GMP.and 12 10 == 8)
    printLn (GMP.ior 12 10 == 14)
    printLn (GMP.xor 12 10 == 6)
    printLn (GMP.com 0 == -1)
    printLn (GMP.com 5 == -6)

    -- nextprime, cross-checked with probabPrimeP rather than a known
    -- constant beyond the one small hand-checkable case.
    printLn (GMP.nextprime 14 == 17)
    printLn (GMP.probabPrimeP (GMP.nextprime big1) 25 > 0)

    -- Predicates/queries
    printLn (GMP.cmp big1 big2 == -1)
    printLn (GMP.cmpabs (negate big1) big1 == 0)
    printLn (GMP.probabPrimeP 17 25 > 0)
    printLn (GMP.probabPrimeP 15 25 == 0)
    printLn (GMP.perfectSquareP 16 /= 0)
    printLn (GMP.perfectSquareP 15 == 0)
    printLn (GMP.perfectPowerP 16 /= 0)
    printLn (GMP.perfectPowerP 15 == 0)
    printLn (GMP.popcount 7 == 3)
    printLn (GMP.popcount 0 == 0)
    printLn (GMP.hamdist 7 0 == 3)
    printLn (GMP.tstbit 5 0 == 1)
    printLn (GMP.tstbit 5 1 == 0)
    printLn (GMP.sizeinbase 200 16 == 2)
    printLn (GMP.sizeinbase 4095 16 == 3)
    printLn (GMP.fitsSlongP 100 /= 0)
    printLn (GMP.fitsSlongP big1 == 0)
    printLn (GMP.fitsUlongP 100 /= 0)
    printLn (GMP.getD 2 == 2.0)
    printLn (GMP.scan0 4 0 == 0)
    printLn (GMP.scan1 4 0 == 2)
