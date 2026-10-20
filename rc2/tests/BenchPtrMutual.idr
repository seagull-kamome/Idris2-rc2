module Main

-- Two functions that tail-call each other (merged into one loop by
-- Compiler.RC2.MutualLoop), both advancing a pointer: its slot should be a
-- native Ptr (rc2/doc/native-pointer.md).
%foreign "CExpr:((char*)$1 + 1)"
prim__next : AnyPtr -> AnyPtr

%foreign "CExpr:((int64_t)*(unsigned char*)$1),libc,stdint.h"
prim__peek : AnyPtr -> Int

%foreign "CExpr:calloc(1, $1),libc,stdlib.h"
prim__calloc : Int -> AnyPtr

pingPong : AnyPtr -> Int -> Int -> Int
pongPing : AnyPtr -> Int -> Int -> Int

pingPong p 0 acc = acc
pingPong p n acc = pongPing (prim__next p) (n - 1) (acc + prim__peek p)

pongPing p 0 acc = acc
pongPing p n acc = pingPong (prim__next p) (n - 1) (acc + prim__peek p)

main : IO ()
main = printLn (pingPong (prim__calloc 200000001) 200000000 0)
