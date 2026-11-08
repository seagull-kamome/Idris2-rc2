module Main

-- A pointer that is the loop variable itself, advanced on every iteration
-- (rc2/doc/native-pointer.md).
%foreign "CExpr:((char*)$1 + 1)"
prim__next : AnyPtr -> AnyPtr

%foreign "CExpr:((int64_t)*(unsigned char*)$1),libc,stdint.h"
prim__peek : AnyPtr -> Int

%foreign "CExpr:calloc(1, $1),libc,stdlib.h"
prim__calloc : Int -> AnyPtr

walk : AnyPtr -> Int -> Int -> Int
walk p acc 0 = acc
walk p acc n = walk (prim__next p) (acc + prim__peek p) (n - 1)

main : IO ()
main = printLn (walk (prim__calloc 200000001) 0 200000000)
