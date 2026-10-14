module Test114Inline.FunDedup

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Compiler.RC2.FunDedup (rc2/doc/fun-dedup.md): functions whose bodies
-- are equal up to the numbering of their locals become one. The two
-- loops below differ only in their names (and each calls itself, which
-- must not make them different); the two wrappers around them are equal
-- once the loops are, which takes a second round. `lastOne` differs
-- from `sumA` in one constant and stays. check.sh asserts on the dump.

sumA : Int -> Int -> Int
sumA acc n = if n <= 0 then acc else sumA (acc + n * 3) (n - 1)

sumB : Int -> Int -> Int
sumB acc n = if n <= 0 then acc else sumB (acc + n * 3) (n - 1)

lastOne : Int -> Int -> Int
lastOne acc n = if n <= 0 then acc else lastOne (acc + n * 4) (n - 1)

-- Called through a list so they stay calls and are not inlined.
wrapA : Int -> Int
wrapA n = sumA 7 n `mod` 1000003 + sumA 1 (n + 1)

wrapB : Int -> Int
wrapB n = sumB 7 n `mod` 1000003 + sumB 1 (n + 1)

export
run : IO ()
run = do
    let fs = [wrapA, wrapB, \n => lastOne 0 n]
    printLn (map (\f => f 10) fs)
    printLn (map (\f => f 100) (reverse fs))
