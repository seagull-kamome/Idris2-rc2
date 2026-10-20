module Main

import Data.Bits

-- A pointer passed to a function that hands it on to %foreign calls, again
-- and again (rc2/doc/native-pointer.md): the parameter stays native.
%foreign "CExpr:((char*)$1 + $2)"
prim__advance : AnyPtr -> Int -> AnyPtr

%foreign "CExpr:((int64_t)*(unsigned char*)$1),libc,stdint.h"
prim__peek : AnyPtr -> Int

%foreign "CExpr:malloc($1),libc,stdlib.h"
prim__malloc : Int -> AnyPtr

at : AnyPtr -> Int -> Int -> Int
at p k 0 = prim__peek (prim__advance p k)
at p k 1 = prim__peek (prim__advance p (k + 1)) + 1
at p k 2 = prim__peek (prim__advance (prim__advance p k) 2) + 2
at p k n = prim__peek (prim__advance p (k + n)) * 3

loop : AnyPtr -> Int -> Int -> Int
loop base acc 0 = acc
loop base acc n = loop base (acc + at base (n .&. 31) (n .&. 3) + at base (n .&. 15) 1) (n - 1)

main : IO ()
main = printLn (loop (prim__malloc 128) 0 200000000)
