module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Text.Regex.POSIX: ERE and BRE compile, matches / match with
-- groups (participating vs. absent vs. empty), ignoreCase, matchAll,
-- replaceFirst / replaceAll, a BRE backreference, rejection of an
-- invalid pattern, byte-offset spans resolved correctly across
-- multi-byte UTF-8 input, and -- since rc2's runtime now does
-- setlocale(LC_ALL, "") in idris2rc2_rtInit -- `.` and POSIX character
-- classes operating by codepoint rather than by byte. That last group
-- depends on a UTF-8 LC_CTYPE; verify.sh runs this under
-- LC_ALL=C.UTF-8. Under a plain "C" locale those same lines would each
-- give the opposite answer (byte-wise matching).

import Data.String
import Text.Regex.POSIX

codes : String -> List Int
codes = map ord . unpack

showParts : Maybe (List (Maybe String)) -> String
showParts = show . map (map (map codes))

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

  -- byte-offset spans must survive a multi-byte char before/inside a
  -- group. "café=αβ" is bytes 63 61 66 C3A9 3D CEB1 CEB2; group1 ends
  -- at byte 5 (not codepoint 5), group2 starts at byte 6.
  utf <- pe "([^=]+)=(.+)"
  putStrLn "utf8 match: \{showParts (match utf "café=αβ")}"
  -- replace across multi-byte context: only the ASCII digit runs go,
  -- the Greek letters are copied by byte span.
  ure <- pe "[0-9]+"
  putStrLn "utf8 replaceAll: \{show (codes (replaceAll ure "#" "α1β22γ"))}"

  -- With a UTF-8 LC_CTYPE, glibc's regex engine matches `.` and POSIX
  -- character classes by codepoint. "café" is 5 bytes / 4 codepoints;
  -- é (U+00E9) is [[:alpha:]] here, not under "C".
  dot <- pe "^.$"
  putStrLn "dot on codepoint: \{showParts (match dot "é")}"
  alpha <- pe "^[[:alpha:]]+$"
  putStrLn "alpha class utf8: \{show (matches alpha "café")}"
  putStrLn "alpha class mixed: \{show (matches alpha "caf3")}"
  quad <- pe "^.{4}$"
  putStrLn "dot count codepoints: \{show (matches quad "café")}"
  putStrLn "dot count too many: \{show (matches quad "caféz")}"

  Left _ <- compile "([unclosed"
    | Right _ => putStrLn "FAIL: invalid pattern accepted"
  putStrLn "invalid rejected"

  putStrLn "--- done ---"
