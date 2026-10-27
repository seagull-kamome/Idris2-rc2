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

import Data.String
import System.Concurrency.RC2
import Text.Regex.RE2

-- One compiled Regex used by several threads: `find` looks pure, so it must
-- not keep its result in the Regex. Each thread matches texts that differ in
-- the key length and the number on every round, so a result that came from
-- the other thread's match shows as a wrong group.
sharedFind : Regex -> Char -> Nat -> IO Nat
sharedFind re letter rounds = go rounds 0
  where
    go : Nat -> Nat -> IO Nat
    go Z bad = pure bad
    go (S k) bad =
      let key = pack (replicate (S (integerToNat (natToInteger k `mod` 9))) letter)
          num = show (k * 7919)
          expected = Just [Just (key ++ "=" ++ num), Just key, Just num]
      in go k (if find re (key ++ "=" ++ num) == expected then bad else S bad)

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


  -- A NUL byte is data in both directions: in the subject, in the
  -- pattern, and in a group or a replacement result.
  Just nul <- compile "b(.)c"
    | Nothing => putStrLn "FAIL: b(.)c rejected"
  putStrLn $ "find b(.)c over NUL: " ++ show (find nul "ab\NULcd")
  putStrLn $ "findFirst past NUL: " ++ show (findFirst "xyz" "ab\NULcd-xyz")
  putStrLn $ "pattern with NUL: " ++ show (matches "a\NULb" "a\NULb")
  Just digit <- compile "[0-9]"
    | Nothing => putStrLn "FAIL: [0-9] rejected"
  putStrLn $ "globalReplace past NUL: " ++ show (globalReplace digit "#" "a\NUL1b2")
  Just shared <- compile "([a-z]+)=([0-9]+)"
    | Nothing => putStrLn "FAIL: ([a-z]+)=([0-9]+) rejected"
  ta <- forkJoin (sharedFind shared 'a' 20000)
  tb <- forkJoin (sharedFind shared 'b' 20000)
  badA <- join ta
  badB <- join tb
  putStrLn $ "shared Regex across two threads, wrong results: " ++ show (badA + badB)
  putStrLn "--- done ---"
