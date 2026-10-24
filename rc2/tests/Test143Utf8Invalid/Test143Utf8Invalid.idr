module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A string read from bytes that are not valid UTF-8 decodes each invalid
-- sequence to one U+FFFD: an overlong form (`C0 AF` is not `/`), a surrogate
-- (`ED A0 80`), a code point past U+10FFFF (`F4 90 80 80`), a stray
-- continuation byte, a truncated sequence. Valid text, including the largest
-- code point of each length, decodes as itself. The bytes are written to a file
-- and read back as a String.

import Data.Buffer
import Data.List
import Data.String.Iterator as Iter
import System.File

%default covering

decoded : String -> List Bits8 -> IO ()
decoded name bytes = do
  let path = "Test143Utf8Invalid.tmp"
  Just buf <- newBuffer (cast (length bytes))
    | Nothing => putStrLn (name ++ ": no buffer")
  traverse_ (\(i, b) => setBits8 buf (cast i) b) (zip [0 .. length bytes] bytes)
  Right () <- writeBufferToFile path buf (cast (length bytes))
    | Left _ => putStrLn (name ++ ": write failed")
  r <- readFile path
  _ <- removeFile path
  case r of
       Left _ => putStrLn (name ++ ": read failed")
       Right s => do
         putStrLn (name ++ ": " ++ show (map ord (Prelude.unpack s)))
         -- the string iterator decodes through its own entry point
         let viaIterator = reverse (Iter.foldl (\acc, c => ord c :: acc) [] s)
         when (viaIterator /= map ord (Prelude.unpack s)) $
           putStrLn (name ++ ": iterator differs: " ++ show viaIterator)

main : IO ()
main = do
  decoded "ascii" [0x61, 0x7F]
  decoded "two bytes" [0xC2, 0x80, 0xDF, 0xBF]
  decoded "three bytes" [0xE0, 0xA0, 0x80, 0xEF, 0xBF, 0xBF]
  decoded "four bytes" [0xF0, 0x90, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF]
  decoded "overlong slash" [0xC0, 0xAF]
  decoded "overlong two" [0xC1, 0xBF]
  decoded "overlong three" [0xE0, 0x80, 0xAF]
  decoded "overlong four" [0xF0, 0x80, 0x80, 0xAF]
  decoded "surrogate low" [0x61, 0xED, 0xA0, 0x80, 0x62]
  decoded "surrogate high" [0xED, 0xBF, 0xBF]
  decoded "past max" [0xF4, 0x90, 0x80, 0x80]
  decoded "lead F5" [0xF5, 0x80, 0x80, 0x80]
  decoded "stray continuation" [0x61, 0x80, 0x62]
  decoded "truncated" [0x61, 0xE2, 0x82]
  decoded "lead then ascii" [0xC3, 0x61]
