module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `newArray` takes an `Int` length and the runtime stores it in an `int`, so a
-- length of 2^32 + 2 used to make a 2-element array whose bounds check (done in
-- Idris, against the length asked for) let a write far past its end through.
-- A length the runtime cannot hold now stops the program with a message.
--
-- Without an argument the program makes ordinary arrays. `../check.sh` runs it
-- again with the argument `big` and expects it to stop, not to corrupt the heap.

import Data.IOArray
import Data.Maybe
import System

%default covering

fill : Int -> IO Int
fill n = do
  arr <- newArray {elem = Int} n
  traverse_ (\i => ignore (writeArray arr i (i * 3))) [0 .. n - 1]
  xs <- traverse (\i => readArray arr i) [0 .. n - 1]
  pure (sum (map (fromMaybe 0) xs))

main : IO ()
main = do
  args <- getArgs
  case args of
       [_, "big"] => do
         arr <- newArray {elem = Int} (4294967296 + 2)
         ignore (writeArray arr 100000 7)
         putStrLn "big array accepted"
       _ => do
         traverse_ (\n => printLn !(fill n)) [0, 1, 10, 1000]
