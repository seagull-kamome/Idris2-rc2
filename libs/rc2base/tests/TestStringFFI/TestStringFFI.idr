module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.String.FFI
import System.FFI

%foreign "C:strdup,string.h"
prim__strdup : String -> PrimIO AnyPtr

%foreign "CExpr:(memset($1, $2, $3)),libc,string.h"
prim__memset : AnyPtr -> Int -> Int -> PrimIO AnyPtr

main : IO ()
main = do
  putStrLn "--- Testing Data.String.FFI ---"

  putStrLn $ "ptrToString on NULL: " ++ show !(ptrToString prim__getNullAnyPtr)

  raw <- primIO (prim__strdup "Hello, rc2base!")
  putStrLn $ "ptrToString on a real C string: " ++ show !(ptrToString raw)
  -- ptrToString copies into a fresh Idris String; the strdup'd
  -- buffer itself is still ours to release.
  free raw

  emptyRaw <- primIO (prim__strdup "")
  putStrLn $ "ptrToString on an empty C string: " ++ show !(ptrToString emptyRaw)
  free emptyRaw

  -- ptrToStringFree copies and then frees; NULL is Nothing and is not freed
  copy <- primIO (prim__strdup "freed after the copy")
  putStrLn $ "ptrToStringFree: " ++ show !(ptrToStringFree copy)
  putStrLn $ "ptrToStringFree on NULL: " ++ show !(ptrToStringFree prim__getNullAnyPtr)

  -- the copy is made when the action runs, before what follows: the source is
  -- overwritten (and a freed block reused) before the copies are shown
  src <- primIO (prim__strdup "original text")
  kept <- ptrToString src
  _ <- primIO (prim__memset src 90 13)
  free src
  src2 <- primIO (prim__strdup "freed text")
  keptFree <- ptrToStringFree src2
  block <- malloc 11
  _ <- primIO (prim__memset block 90 10)
  free block
  putStrLn $ "copy after the source was overwritten: " ++ show kept
  putStrLn $ "copy of ptrToStringFree after the block was reused: " ++ show keptFree

  putStrLn "--- Tests finished ---"
