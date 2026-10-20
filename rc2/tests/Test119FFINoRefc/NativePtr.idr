module Test119FFINoRefc.NativePtr

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A pointer is an immediate boxed word unless its top bit is set
-- (rc2/doc/native-pointer.md): every address must survive the round trip,
-- through a list, a closure and a `GCAnyPtr`.

import Data.IORef
import Data.List

%foreign "CExpr:((void*)(uintptr_t)$1),libc,stdint.h"
prim__ptrOf : Bits64 -> AnyPtr

%foreign "CExpr:((uint64_t)(uintptr_t)$1),libc,stdint.h"
prim__addrOf : AnyPtr -> Bits64

addrs : List Bits64
addrs = [0, 1, 7, 4096, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff, 0xdeadbeefcafe0001]

-- A pointer parameter handed on to a %foreign call, through two functions
-- that call each other so neither is inlined.
mutual
  outer : Nat -> AnyPtr -> Bits64
  outer Z p = prim__addrOf p
  outer (S k) p = inner k p + 0

  inner : Nat -> AnyPtr -> Bits64
  inner k p = outer k p + 1

-- A pointer that is the loop variable itself; 0x7fff...ffff crosses into the
-- heap-box range on the way.
%foreign "CExpr:((char*)$1 + 1)"
prim__next : AnyPtr -> AnyPtr

walk : AnyPtr -> Int -> AnyPtr
walk p 0 = p
walk p n = walk (prim__next p) (n - 1)

-- Two functions that tail-call each other are merged into one loop
-- (doc/loop-conversion.md); `padA` has a pointer slot `padB` leaves unused,
-- which the merged loop fills with a null pointer.
padA : AnyPtr -> AnyPtr -> Int -> Bits64
padB : AnyPtr -> Int -> Bits64

padA p q 0 = prim__addrOf p + prim__addrOf q
padA p q n = padB (prim__next p) (n - 1)

padB p 0 = prim__addrOf p
padB p n = padA p (prim__next p) (n - 1)

collected : IORef Nat -> IO ()
collected c = do
  let p = prim__ptrOf 4096
  g <- onCollectAny p (\_ => modifyIORef c (+ 1))
  pure ()

export
run : IO ()
run = do
  let ps = map prim__ptrOf addrs
  printLn (map prim__addrOf ps)
  printLn (map (\a => prim__addrOf (prim__ptrOf a)) addrs)
  let f = \p => prim__addrOf p + 1
  printLn (map f ps)
  printLn (map (\p => outer 3 p) ps)
  printLn (map (\a => padA (prim__ptrOf a) (prim__ptrOf 1) 5) (filter (/= 0xffffffffffffffff) addrs))
  printLn (map (\a => prim__addrOf (walk (prim__ptrOf a) 5)) (filter (/= 0xffffffffffffffff) addrs))
  printLn (prim__nullAnyPtr (prim__ptrOf 0) /= 0, prim__nullAnyPtr (prim__ptrOf 8) /= 0)
  c <- newIORef 0
  collected c
  readIORef c >>= printLn
