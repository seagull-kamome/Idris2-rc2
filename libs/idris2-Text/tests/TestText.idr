module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Text
import Data.Fin
import Data.String

main : IO ()
main = do
  putStrLn "--- Testing idris2-Text ---"

  let (n1 ** txt1) = fromString "Hello"
  putStrLn $ "Text: Hello, Length: " ++ show n1

  case natToFin 1 n1 of
    Just idx => do
      let c = Data.Text.index txt1 idx
      putStrLn $ "Character at index 1: " ++ singleton c
    Nothing => putStrLn "Index 1 out of bounds"

  let (_ ** txt2) = fromString "World"
  let txt3 = txt1 ++ txt2
  let len3 = Data.Text.length txt3
  putStrLn $ "Appended: Hello + World, Length: " ++ show len3
  putStrLn $ "Round-trip toString: " ++ Data.Text.toString txt3

  let (_ ** txt4) = fromString "Hello, 世界! 😀"
  putStrLn $ "Multi-byte length: " ++ show (Data.Text.length txt4)
  putStrLn $ "Multi-byte round-trip: " ++ Data.Text.toString txt4

  putStrLn "--- Tests finished ---"
