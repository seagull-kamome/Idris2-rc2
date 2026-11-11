module Main

-- An rc2 program that calls two rc2 libraries, with the runtime shared by all three
-- (--directive sharedruntime).

%foreign "C:libadd_two,libaddlib,addlib.h"
prim__add1 : Int -> Int -> PrimIO Int
%foreign "C:lib2_add_two,libadd2lib,add2lib.h"
prim__add2 : Int -> Int -> PrimIO Int

main : IO ()
main = do
  a <- primIO (prim__add1 1 2)
  b <- primIO (prim__add2 10 20)
  printLn (a, b)
