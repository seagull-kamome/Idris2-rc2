module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.TextBuffer
import Data.Fin
import Data.String

main : IO ()
main = do
  putStrLn "--- Testing idris2-Text ---"

  let (n1 ** txt1) = fromString "Hello"
  putStrLn $ "Text: Hello, Length: " ++ show n1

  case natToFin 1 n1 of
    Just idx => do
      let c = Data.TextBuffer.index txt1 idx
      putStrLn $ "Character at index 1: " ++ Data.TextBuffer.toString (Data.TextBuffer.singleton c)
    Nothing => putStrLn "Index 1 out of bounds"

  let (_ ** txt2) = fromString "World"
  let txt3 = txt1 ++ txt2
  let len3 = Data.TextBuffer.length txt3
  putStrLn $ "Appended: Hello + World, Length: " ++ show len3
  putStrLn $ "Round-trip toString: " ++ Data.TextBuffer.toString txt3

  let (_ ** txt4) = fromString "Hello, 世界! 😀"
  putStrLn $ "Multi-byte length: " ++ show (Data.TextBuffer.length txt4)
  putStrLn $ "Multi-byte round-trip: " ++ Data.TextBuffer.toString txt4

  putStrLn "--- Testing new string ops ---"

  let (_ ** sub) = substr 1 3 txt3
  putStrLn $ "substr 1 3 \"HelloWorld\": " ++ toString sub

  let (_ ** cat) = concat [(n1 ** txt1), (_ ** txt2)]
  putStrLn $ "concat [Hello, World]: " ++ toString cat

  let (_ ** sep) = fromString ", "
  let (_ ** joined) = joinBy sep [(n1 ** txt1), (_ ** txt2)]
  putStrLn $ "joinBy \", \" [Hello, World]: " ++ toString joined

  putStrLn $ "singleton 'x': " ++ toString (singleton 'x')
  putStrLn $ "replicate 5 'z': " ++ toString (replicate 5 'z')

  let (_ ** padl) = padLeft 8 '.' txt1
  putStrLn $ "padLeft 8 '.' \"Hello\": " ++ toString padl
  let (_ ** padr) = padRight 8 '.' txt1
  putStrLn $ "padRight 8 '.' \"Hello\": " ++ toString padr

  let (_ ** spaced) = fromString "  spaced out  "
  let (_ ** lt) = ltrim spaced
  let (_ ** rt) = rtrim spaced
  let (_ ** tr) = trim spaced
  putStrLn $ "ltrim: [" ++ toString lt ++ "]"
  putStrLn $ "rtrim: [" ++ toString rt ++ "]"
  putStrLn $ "trim: [" ++ toString tr ++ "]"

  let (_ ** sentence) = fromString "the quick  brown fox"
  putStrLn $ "words: " ++ show (map (\(_ ** w) => toString w) (words sentence))
  let (_ ** rejoined) = unwords (words sentence)
  putStrLn $ "unwords . words: " ++ toString rejoined

  let (_ ** multiline) = fromString "line1\nline2\r\nline3"
  putStrLn $ "lines: " ++ show (map (\(_ ** l) => toString l) (lines multiline))
  let (_ ** unlined) = unlines (lines multiline)
  putStrLn $ "unlines . lines: [" ++ toString unlined ++ "]"

  let ((_ ** spanA), (_ ** spanB)) = Data.TextBuffer.span (/= ' ') sentence
  putStrLn $ "span (/= ' '): (" ++ toString spanA ++ ", " ++ toString spanB ++ ")"
  let ((_ ** breakA), (_ ** breakB)) = Data.TextBuffer.break (== ' ') sentence
  putStrLn $ "break (== ' '): (" ++ toString breakA ++ ", " ++ toString breakB ++ ")"

  let (_ ** csv) = fromString "a,b,,c"
  putStrLn $ "split (== ','): " ++ show (map (\(_ ** s) => toString s) (Data.TextBuffer.split (== ',') csv))

  let (_ ** empty) = fromString ""
  putStrLn $ "toString of an empty Text: [" ++ toString empty ++ "]"

  putStrLn $ "toUpper \"Hello\": " ++ toString (toUpper txt1)
  putStrLn $ "toLower \"Hello\": " ++ toString (toLower txt1)

  putStrLn "--- Tests finished ---"
