module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A String holding a NUL byte (IDRIS2RC2_String carries its length,
-- idris2rc2_datatypes.h). `s`/`t` put a digit right after the NUL, so a
-- NUL escaped as `\0` or `\x00` in the emitted C would swallow it.
-- `putStr s` prints only "ab": a String crosses the FFI as `->str`, cut
-- at the first NUL, which is accepted.

import Data.Buffer
import Data.String
import Data.String.Iterator
import Data.String.RC2
import Data.TextBuffer

-- Every index below is known in range by construction; strIndex/strTail
-- are only `partial` because they can't express that statically (same
-- convention as Test28Utf8Strings).
idx : String -> Int -> Char
idx = assert_total strIndex

tailOf : String -> String
tailOf = assert_total strTail

-- The iterator calls get the string as a `char *` unless rc2 sends them to
-- its length-aware replacements.
iterCount : String -> Nat
iterCount = Data.String.Iterator.foldl (\n, _ => S n) 0

-- `Data.TextBuffer.fromString` hands C the String itself, not `->str`.
textRoundTrip : String -> (Nat, Bool)
textRoundTrip str =
  let t = Data.TextBuffer.fromString str
  in (Data.TextBuffer.length t, Data.TextBuffer.toString t == str)

-- Data.Buffer's stringByteLength, setString and getString take or give a
-- `char *` upstream; rc2 sends them to length-aware replacements
-- (fastpack-fix.md), so the bytes after the NUL are counted, written and read.
bufferCheck : String -> IO ()
bufferCheck str = do
  let n = stringByteLength str
  Just buf <- newBuffer 16
    | Nothing => putStrLn "no buffer"
  setString buf 0 str
  back <- getString buf 0 n
  bytes <- traverse (getBits8 buf) [0 .. n - 1]
  printLn (n, back == str, Prelude.unpack back)
  printLn bytes
  setString buf 3 str
  shifted <- getString buf 3 n
  printLn (shifted == str)
  empty <- getString buf 3 0
  printLn (stringByteLength "", empty)

afterFirst : String -> String
afterFirst str = withString str $ \it => case uncons str it of
  EOF => ""
  Character _ it' => withIteratorString str it' id

-- A fused `cmp` over Boxed Strings (doc/native-type-inference.md) must
-- order by bytes and length, never stop at a NUL.
cmp5 : String -> String -> String
cmp5 x y = (if x < y then "<" else "") ++ (if x == y then "=" else "")
        ++ (if x > y then ">" else "") ++ (if x <= y then "L" else "")
        ++ (if x >= y then "G" else "") ++ (if x /= y then "N" else "")

cmpStrings : List String
cmpStrings = ["", "a", "a\NUL", "a\NUL1", "a\NUL2", "ab", "\955", "\955\946", "\946", "\128512"]

s : String
s = "ab\NUL1cd"

t : String
t = "ab\NUL2cd"

main : IO ()
main = do
    printLn (length s)
    printLn s
    printLn (s ++ "!!")
    printLn (strSubstr 2 2 s)
    printLn (idx s 2)
    printLn (strUncons s)
    printLn (tailOf s)
    printLn (strCons '#' s)
    printLn (reverse s)
    printLn (s == s)
    printLn (s == t)
    printLn (compare s t)
    let chars = unpack s
    printLn chars
    printLn (pack chars == s)
    printLn (iterCount s)
    printLn (afterFirst s)
    printLn (byteLength s)
    printLn (unsafeStringByteSlice s 1 3)
    printLn (textRoundTrip s)
    bufferCheck s
    bufferCheck "\955\NUL1"
    printLn (cast {to=String} (the Int 0))
    case s of
         "ab\NUL1cd" => putStrLn "case: matched own literal"
         _           => putStrLn "case: WRONG (own literal)"
    case t of
         "ab\NUL1cd" => putStrLn "case: WRONG (cross match)"
         _           => putStrLn "case: correctly distinct past the NUL"
    for_ cmpStrings $ \x => putStrLn (unwords (map (cmp5 x) cmpStrings))
    putStr s
    putStrLn ""
    putStrLn "done"
