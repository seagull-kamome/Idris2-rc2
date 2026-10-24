module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `%export` of a function with as many arguments as the exporter allows (20).
-- An `IO` function has one more parameter than it declares (the world), so its
-- compiled entry point takes 21 and is declared with an argument array instead
-- of positional parameters; the exported C wrapper has to call it that way.
-- Each argument is weighted by its position so a swapped or shifted argument
-- changes the result. The functions are called from plain C (the companion
-- Test138ExportWideIO.c) through `prim__callFromC`.

%export "C:idris2rc2_test138_wide_io"
wideIO : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO Int
wideIO a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 = pure (a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20)

%export "C:idris2rc2_test138_wide_pure"
widePure : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
widePure a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 = a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20

-- one below the limit: 20 parameters with the world, still positional
%export "C:idris2rc2_test138_narrow_io"
narrowIO : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO Int
narrowIO a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 = pure (a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19)

%foreign "C:idris2rc2_test138_run,libc,Test138ExportWideIO.h"
prim__run : Int -> PrimIO Int

main : IO ()
main = do
  r <- primIO (prim__run 0)
  printLn r
  r1 <- primIO (prim__run 1)
  printLn r1
  r2 <- primIO (prim__run 2)
  printLn r2
