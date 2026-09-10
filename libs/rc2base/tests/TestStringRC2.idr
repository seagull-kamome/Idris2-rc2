module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Data.String.RC2: unsafeStringByteSlice on ASCII, on a
-- multi-byte UTF-8 boundary, cutting mid-codepoint (-> U+FFFD),
-- the C-side clamping of out-of-range off/len, and byteLength vs
-- codepoint length.

import Data.String
import Data.String.RC2

codes : String -> List Int
codes = map ord . unpack

main : IO ()
main = do
  putStrLn "--- Data.String.RC2 ---"
  putStrLn "slice ascii: \{unsafeStringByteSlice "hello world" 6 5}"
  putStrLn "byteLength hello: \{show (byteLength "hello")}"
  putStrLn "byteLength cafe-acute: \{show (byteLength "café")}"
  putStrLn "length cafe-acute: \{show (String.length "café")}"
  putStrLn "slice on boundary: \{show (codes (unsafeStringByteSlice "café=λ" 0 5))}"
  putStrLn "slice tail char: \{show (codes (unsafeStringByteSlice "café=λ" 6 2))}"
  putStrLn "slice mid-codepoint: \{show (codes (unsafeStringByteSlice "café" 3 1))}"
  putStrLn "clamp over-len: \{unsafeStringByteSlice "abc" 1 100}"
  putStrLn "clamp neg off: \{unsafeStringByteSlice "abc" (-3) 2}"
  putStrLn "clamp neg len: \{show (codes (unsafeStringByteSlice "abc" 1 (-5)))}"
  putStrLn "off past end: \{show (codes (unsafeStringByteSlice "abc" 9 3))}"
  putStrLn "empty in empty: \{show (codes (unsafeStringByteSlice "" 0 0))}"
  putStrLn "--- done ---"
