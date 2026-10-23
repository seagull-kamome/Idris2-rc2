module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.String.FFI
import System.FFI

%foreign "C:strdup,string.h"
prim__strdup : String -> PrimIO AnyPtr

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

  putStrLn "--- Tests finished ---"
