module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.ConstFold's constant-constructor
-- folding (RCConstCon, see RCExp.idr's own doc comment): a
-- constructor whose fields are all -- recursively -- constant folds
-- to a single immortal value staged once as a file-scope static
-- (Compiler.RC2.Emit's ConstConDef), instead of a fresh heap
-- allocation on every evaluation.

constList : List Int
constList = [1,2,3,4,5]

constMaybe : Maybe Int
constMaybe = Just 42

nestedConst : List (Maybe Int)
nestedConst = [Just 1, Nothing, Just 3]

-- Partial fold: `x` stays dynamic, but the `constList` tail is still
-- referenced as the staged static directly.
partialConst : Int -> List Int
partialConst x = x :: constList

-- Destructures the same immortal constant constructor from multiple
-- call sites -- exercises whether the dup/drop the caller wraps
-- around the extracted field (a genuine heap-shared-looking read)
-- stays a safe no-op against the REFCOUNT_MAX marker.
headOf : List Int -> Int
headOf (x :: _) = x
headOf [] = 0

tailOf : List Int -> List Int
tailOf (_ :: xs) = xs
tailOf [] = []

unwrapMaybe : Maybe Int -> Int
unwrapMaybe (Just x) = x
unwrapMaybe Nothing = 0

main : IO ()
main = do
  printLn constList
  printLn constMaybe
  printLn nestedConst
  printLn (partialConst 99)
  printLn (partialConst 100)
  printLn (headOf constList)
  printLn (tailOf constList)
  printLn (headOf constList)
  printLn (unwrapMaybe constMaybe)
  printLn (unwrapMaybe constMaybe)
  printLn (map unwrapMaybe nestedConst)
