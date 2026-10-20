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
  let f = \p => prim__addrOf p + 1
  printLn (map f ps)
  printLn (prim__nullAnyPtr (prim__ptrOf 0) /= 0, prim__nullAnyPtr (prim__ptrOf 8) /= 0)
  c <- newIORef 0
  collected c
  readIORef c >>= printLn
