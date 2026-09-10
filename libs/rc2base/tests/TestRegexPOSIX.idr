module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Text.Regex.POSIX: ERE and BRE compile, matches / match with
-- groups (participating vs. absent vs. empty), ignoreCase, matchAll,
-- replaceFirst / replaceAll, a BRE backreference, and rejection of an
-- invalid pattern.

import Text.Regex.POSIX

pe : {default ere flags : Flags} -> String -> IO Regex
pe {flags} pat = do
  Right re <- compile {flags} pat
    | Left e => assert_total (idris_crash ("compile failed: " ++ e))
  pure re

main : IO ()
main = do
  putStrLn "--- Text.Regex.POSIX ---"

  kv <- pe "([a-z]+)=([0-9]+)"
  putStrLn "groupCount: \{show (groupCount kv)}"
  putStrLn "matches: \{show (matches kv "x foo=42 y")}"
  putStrLn "match: \{show (match kv "x foo=42 y")}"
  putStrLn "no match: \{show (match kv "nope")}"

  alt <- pe "(a)|(b)"
  putStrLn "alt on b: \{show (match alt "b")}"
  putStrLn "alt on a: \{show (match alt "a")}"

  opt <- pe "x(a*)y"
  putStrLn "empty group: \{show (match opt "xy")}"

  ci <- pe {flags = { ignoreCase := True } ere} "hello"
  putStrLn "ignoreCase: \{show (matches ci "oh HELLO there")}"

  digits <- pe "[0-9]+"
  putStrLn "matchAll: \{show (matchAll digits "a12b345c9")}"

  pair <- pe "([a-z]+):([0-9]+)"
  putStrLn "replaceFirst: \{replaceFirst pair "[\\1=\\2]" "a:1 b:2"}"
  putStrLn "replaceAll: \{replaceAll pair "[\\1=\\2]" "a:1 b:2"}"

  bref <- pe {flags = bre} "\\([a-z]\\)\\1"
  putStrLn "BRE backref (has dd): \{show (matches bref "abcdd")}"
  putStrLn "BRE backref (no double): \{show (matches bref "abcde")}"

  Left _ <- compile "([unclosed"
    | Right _ => putStrLn "FAIL: invalid pattern accepted"
  putStrLn "invalid rejected"

  putStrLn "--- done ---"
