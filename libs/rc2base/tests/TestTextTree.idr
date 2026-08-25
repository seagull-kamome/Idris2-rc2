module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Text
import Data.Fin

main : IO ()
main = do
  putStrLn "--- Testing Data.Text (finger tree) ---"

  let txt1 = fromString "Hello"
  putStrLn $ "Text: Hello, Length: " ++ show (Data.Text.length txt1)

  case natToFin 1 (Data.Text.length txt1) of
    Just idx => putStrLn $ "Character at index 1: " ++ toString (Data.Text.singleton (Data.Text.index txt1 idx))
    Nothing => putStrLn "Index 1 out of bounds"

  let txt2 = fromString "World"
  let txt3 = txt1 ++ txt2
  putStrLn $ "Appended: Hello + World, Length: " ++ show (Data.Text.length txt3)
  putStrLn $ "Round-trip toString: " ++ toString txt3

  let txt4 = fromString "Hello, 世界! 😀"
  putStrLn $ "Multi-byte length: " ++ show (Data.Text.length txt4)
  putStrLn $ "Multi-byte round-trip: " ++ toString txt4

  -- Exercise the tree structure itself: repeated small (++) is the
  -- whole point of this module, not just a single append.
  let manyparts = Data.Text.concat (map Data.Text.singleton (unpack "abcdefghijklmnopqrstuvwxyz"))
  putStrLn $ "concat of 26 singletons: " ++ toString manyparts ++ ", length: " ++ show (Data.Text.length manyparts)

  -- Force a Deep+Deep (++) -- concat's own fold only ever appends a
  -- Single onto an accumulator, never exercising addDigits0's actual
  -- digit-regrouping path. Two already-multi-chunk trees, appended
  -- directly, do.
  let left20 = Data.Text.concat (map Data.Text.singleton (unpack "ABCDEFGHIJKLMNOPQRST"))
  let right20 = Data.Text.concat (map Data.Text.singleton (unpack "UVWXYZ0123456789+-*/"))
  let deepPlusDeep = left20 ++ right20
  putStrLn $ "Deep++Deep: " ++ toString deepPlusDeep ++ ", length: " ++ show (Data.Text.length deepPlusDeep)

  let sub = substr 1 3 txt3
  putStrLn $ "substr 1 3 \"HelloWorld\": " ++ toString sub

  let cat = Data.Text.concat [txt1, txt2]
  putStrLn $ "concat [Hello, World]: " ++ toString cat

  let sep = fromString ", "
  let joined = joinBy sep [txt1, txt2]
  putStrLn $ "joinBy \", \" [Hello, World]: " ++ toString joined

  putStrLn $ "singleton 'x': " ++ toString (Data.Text.singleton 'x')
  putStrLn $ "replicate 5 'z': " ++ toString (Data.Text.replicate 5 'z')

  let padl = padLeft 8 '.' txt1
  putStrLn $ "padLeft 8 '.' \"Hello\": " ++ toString padl
  let padr = padRight 8 '.' txt1
  putStrLn $ "padRight 8 '.' \"Hello\": " ++ toString padr

  let spaced = fromString "  spaced out  "
  let lt = ltrim spaced
  let rt = rtrim spaced
  let tr = trim spaced
  putStrLn $ "ltrim: [" ++ toString lt ++ "]"
  putStrLn $ "rtrim: [" ++ toString rt ++ "]"
  putStrLn $ "trim: [" ++ toString tr ++ "]"

  let sentence = fromString "the quick  brown fox"
  putStrLn $ "words: " ++ show (map toString (words sentence))
  let rejoined = unwords (words sentence)
  putStrLn $ "unwords . words: " ++ toString rejoined

  let multiline = fromString "line1\nline2\r\nline3"
  putStrLn $ "lines: " ++ show (map toString (lines multiline))
  let unlined = unlines (lines multiline)
  putStrLn $ "unlines . lines: [" ++ toString unlined ++ "]"

  let (spanA, spanB) = Data.Text.span (/= ' ') sentence
  putStrLn $ "span (/= ' '): (" ++ toString spanA ++ ", " ++ toString spanB ++ ")"
  let (breakA, breakB) = Data.Text.break (== ' ') sentence
  putStrLn $ "break (== ' '): (" ++ toString breakA ++ ", " ++ toString breakB ++ ")"

  let csv = fromString "a,b,,c"
  putStrLn $ "split (== ','): " ++ show (map toString (Data.Text.split (== ',') csv))

  let empty = fromString ""
  putStrLn $ "toString of an empty Text: [" ++ toString empty ++ "]"

  putStrLn $ "toUpper \"Hello\": " ++ toString (toUpper txt1)
  putStrLn $ "toLower \"Hello\": " ++ toString (toLower txt1)

  putStrLn "--- Tests finished ---"
