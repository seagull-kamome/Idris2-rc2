module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.TextBuffer
import Data.Fin
import Data.String

main : IO ()
main = do
  putStrLn "--- Testing idris2-Text ---"

  let txt1 = fromString "Hello"
  putStrLn $ "Text: Hello, Length: " ++ show (Data.TextBuffer.length txt1)

  case natToFin 1 (Data.TextBuffer.length txt1) of
    Just idx => do
      let c = Data.TextBuffer.index txt1 idx
      putStrLn $ "Character at index 1: " ++ Data.TextBuffer.toString (Data.TextBuffer.singleton c)
    Nothing => putStrLn "Index 1 out of bounds"

  let txt2 = fromString "World"
  let txt3 = txt1 ++ txt2
  let len3 = Data.TextBuffer.length txt3
  putStrLn $ "Appended: Hello + World, Length: " ++ show len3
  putStrLn $ "Round-trip toString: " ++ Data.TextBuffer.toString txt3

  let txt4 = fromString "Hello, 世界! 😀"
  putStrLn $ "Multi-byte length: " ++ show (Data.TextBuffer.length txt4)
  putStrLn $ "Multi-byte round-trip: " ++ Data.TextBuffer.toString txt4

  putStrLn "--- Testing new string ops ---"

  let sub = substr 1 3 txt3 {ok = believe_me ()}
  putStrLn $ "substr 1 3 \"HelloWorld\": " ++ toString sub

  let cat = concat [txt1, txt2]
  putStrLn $ "concat [Hello, World]: " ++ toString cat

  let sep = fromString ", "
  let joined = joinBy sep [txt1, txt2]
  putStrLn $ "joinBy \", \" [Hello, World]: " ++ toString joined

  putStrLn $ "singleton 'x': " ++ toString (singleton 'x')
  putStrLn $ "replicate 5 'z': " ++ toString (replicate 5 'z')

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

  let (spanA, spanB) = Data.TextBuffer.span (/= ' ') sentence
  putStrLn $ "span (/= ' '): (" ++ toString spanA ++ ", " ++ toString spanB ++ ")"
  let (breakA, breakB) = Data.TextBuffer.break (== ' ') sentence
  putStrLn $ "break (== ' '): (" ++ toString breakA ++ ", " ++ toString breakB ++ ")"

  let csv = fromString "a,b,,c"
  putStrLn $ "split (== ','): " ++ show (map toString (Data.TextBuffer.split (== ',') csv))

  let empty = fromString ""
  putStrLn $ "toString of an empty Text: [" ++ toString empty ++ "]"

  putStrLn $ "toUpper \"Hello\": " ++ toString (toUpper txt1)
  putStrLn $ "toLower \"Hello\": " ++ toString (toLower txt1)

  putStrLn "--- Tests finished ---"
