module Main

import Data.Bits

-- A pointer produced and consumed on every iteration: an advance by a
-- byte offset and a read through it (rc2/doc/native-pointer.md).
%foreign "CExpr:((char*)$1 + $2)"
prim__advance : AnyPtr -> Int -> AnyPtr

%foreign "CExpr:((int64_t)*(unsigned char*)$1),libc,stdint.h"
prim__peek : AnyPtr -> Int

%foreign "CExpr:malloc($1),libc,stdlib.h"
prim__malloc : Int -> AnyPtr

loop : AnyPtr -> Int -> Int -> Int
loop base acc 0 = acc
loop base acc n = loop base (acc + prim__peek (prim__advance base (n .&. 63))) (n - 1)

main : IO ()
main = printLn (loop (prim__malloc 64) 0 200000000)
