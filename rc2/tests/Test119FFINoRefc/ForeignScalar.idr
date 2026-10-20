module Test119FFINoRefc.ForeignScalar

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A parameter or loop variable that is only ever a %foreign scalar argument
-- is native across the call (rc2/doc/native-pointer.md's neighbours: the
-- same call-argument analysis). Values beyond the immediate range check the
-- conversions at the boundary. No `C:` twin: real RefC is not diffed.

%foreign "CExpr:(($1) + 1),libc,stdint.h"
prim__inc : Int -> Int

%foreign "CExpr:(($1) ^ 0xff),libc,stdint.h"
prim__flip8 : Bits8 -> Bits8

%foreign "CExpr:(($1) * 3),libc,stdint.h"
prim__triple : Bits64 -> Bits64

%foreign "CExpr:(($1) + 1),libc,stdint.h"
prim__nextChar : Char -> Char

-- Recursion keeps each of these a real function with the parameter as an
-- argument of the call and nothing else.
viaInc : Int -> Int -> Int
viaInc x 0 = prim__inc x
viaInc x n = viaInc x (n - 1) + 0

viaFlip : Bits8 -> Int -> Bits8
viaFlip x 0 = prim__flip8 x
viaFlip x n = viaFlip x (n - 1)

viaNext : Char -> Int -> Char
viaNext c 0 = prim__nextChar c
viaNext c n = viaNext c (n - 1)

-- The loop variable `k` is only read by the %foreign call.
tripleLoop : Bits64 -> Int -> Bits64
tripleLoop k 0 = k
tripleLoop k n = tripleLoop (prim__triple k) (n - 1)

-- Two functions that tail-call each other, both only feeding the variable
-- to the call.
pingInc : Int -> Int -> Int
pongInc : Int -> Int -> Int
pingInc k 0 = k
pingInc k n = pongInc (prim__inc k) (n - 1)
pongInc k 0 = k
pongInc k n = pingInc (prim__inc k) (n - 1)

export
run : IO ()
run = do
  printLn (map (\x => viaInc x 3) [0, -1, 4611686018427387904, 9223372036854775806])
  printLn (map (\x => viaFlip x 2) [0, 1, 255])
  printLn (map (\c => viaNext c 2) ['a', 'y'])
  printLn (map (\k => tripleLoop k 5) [0, 1, 0x5555555555555555, 0xffffffffffffffff])
  printLn (map (\k => pingInc k 7) [0, -1, 4611686018427387900])
