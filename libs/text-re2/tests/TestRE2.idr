module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Text.Regex.RE2 end to end: compile (valid + invalid),
-- fullMatch/partialMatch, numGroups, find (including the per-group
-- "didn't participate" Nothing vs. Just "" distinction), the two
-- replace variants, and the compile-every-call shorthands.
--
-- Prints to stdout only; RE2/abseil write a one-time logging line (and
-- invalid-pattern parse errors) to stderr, so verify.sh diffs stdout
-- alone.

import Text.Regex.RE2

main : IO ()
main = do
  putStrLn "--- Text.Regex.RE2 ---"

  Just kv <- compile "([a-z]+)=([0-9]+)"
    | Nothing => putStrLn "FAIL: valid pattern rejected"
  putStrLn "compiled ([a-z]+)=([0-9]+)"
  putStrLn $ "numGroups: " ++ show (numGroups kv)
  putStrLn $ "fullMatch \"foo=42\": " ++ show (fullMatch kv "foo=42")
  putStrLn $ "fullMatch \"foo=42 \": " ++ show (fullMatch kv "foo=42 ")
  putStrLn $ "partialMatch \"x foo=42 y\": " ++ show (partialMatch kv "x foo=42 y")
  putStrLn $ "find \"foo=42 bar=7\": " ++ show (find kv "foo=42 bar=7")
  putStrLn $ "replaceFirst: "  ++ replaceFirst  kv "[\\1:\\2]" "foo=42 bar=7"
  putStrLn $ "globalReplace: " ++ globalReplace kv "[\\1:\\2]" "foo=42 bar=7"

  Just alt <- compile "(a)|(b)"
    | Nothing => putStrLn "FAIL: (a)|(b) rejected"
  putStrLn $ "find (a)|(b) on \"b\": " ++ show (find alt "b")
  putStrLn $ "find (a)|(b) on \"a\": " ++ show (find alt "a")

  Nothing <- compile "([unclosed"
    | Just _ => putStrLn "FAIL: invalid pattern accepted"
  putStrLn "invalid pattern rejected"

  putStrLn $ "matches \"[0-9]+\" \"12345\": " ++ show (matches "[0-9]+" "12345")
  putStrLn $ "matches \"[0-9]+\" \"12a45\": " ++ show (matches "[0-9]+" "12a45")
  putStrLn $ "findFirst \"(\\w)(\\d)\" \"x7\": " ++ show (findFirst "(\\w)(\\d)" "x7")
  putStrLn $ "findFirst \"(\" \"x\": " ++ show (findFirst "(" "x")

  putStrLn "--- done ---"
