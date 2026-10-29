module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A `Str` literal is an immortal static, so ConstFold substitutes it like a
-- native constant (rc2/doc/const-caf-fold.md, "String literals"): a CAF that is
-- a string (also the ones `prim__codegen` folds to), a `let`-bound string, a
-- comparison of two known strings and a `case` on a known string all fold.
-- check.sh looks at the IR; the output must be right either way, and valgrind
-- (this test is in LEAK_SENSITIVE_TESTS) must see no definitely lost bytes and
-- no invalid free of a literal.

import System
import System.Info

greeting : String
greeting = "hello"

record Named where
  constructor MkNamed
  label : String
  count : Nat

named : Named
named = MkNamed greeting 3

describe : String -> String
describe "hello" = "greeting"
describe "rc2" = "backend"
describe _ = "other"

-- A literal handed to a function that consumes it, twice.
twice : String -> String
twice s = s ++ s

-- The folded `< <= > >= ==` of two literals must give what the runtime gives:
-- bytewise, no locale (idris2rc2_strcmp3). `orderFolded` is written with
-- literals so every comparison folds; `orderRuntime` gets the same strings
-- through `pack . unpack`, which is not folded.
orderOps : (String -> String -> Bool) -> (String -> String -> Bool) -> (String -> String -> Bool) ->
           (String -> String -> Bool) -> (String -> String -> Bool) -> List (String, String) -> List Bool
orderOps lt lte gt gte eq = concatMap (\(a, b) => [lt a b, lte a b, gt a b, gte a b, eq a b])

orderFolded : List Bool
orderFolded =
  concat
    [ [ "a" < "b", "a" <= "b", "a" > "b", "a" >= "b", "a" == "b" ]
    , [ "Z" < "a", "Z" <= "a", "Z" > "a", "Z" >= "a", "Z" == "a" ]
    , [ "é" < "z", "é" <= "z", "é" > "z", "é" >= "z", "é" == "z" ]
    , [ "あ" < "a", "あ" <= "a", "あ" > "a", "あ" >= "a", "あ" == "a" ]
    , [ "abc" < "ab", "abc" <= "ab", "abc" > "ab", "abc" >= "ab", "abc" == "ab" ]
    , [ "" < "a", "" <= "a", "" > "a", "" >= "a", "" == "a" ]
    , [ "日本" < "日本語", "日本" <= "日本語", "日本" > "日本語", "日本" >= "日本語", "日本" == "日本語" ]
    , [ "\x1F600" < "\xFFFF", "\x1F600" <= "\xFFFF", "\x1F600" > "\xFFFF", "\x1F600" >= "\xFFFF", "\x1F600" == "\xFFFF" ]
    , [ "x" < "x", "x" <= "x", "x" > "x", "x" >= "x", "x" == "x" ]
    ]

orderRuntime : List Bool
orderRuntime =
  orderOps (\a, b => re a < re b) (\a, b => re a <= re b) (\a, b => re a > re b)
           (\a, b => re a >= re b) (\a, b => re a == re b)
           [("a", "b"), ("Z", "a"), ("é", "z"), ("あ", "a"), ("abc", "ab"), ("", "a"),
            ("日本", "日本語"), ("\x1F600", "\xFFFF"), ("x", "x")]
  where
    re : String -> String
    re = pack . unpack

orderReport : (List Bool, List Bool) -> String
orderReport (f, r) = (if f == r then "order: folded = runtime " else "order: DIFFERENT ") ++ show (length f)

main : IO ()
main = do
  args <- getArgs
  let dyn = case args of
              (_ :: x :: _) => x
              _ => "hello"
  putStrLn (if greeting == "hello" then "caf equal" else "caf differs")
  putStrLn (if greeting == "bye" then "caf equal" else "caf differs")
  putStrLn (if codegen == "rc2" then "codegen rc2" else "codegen other")
  let local = "local"
  putStrLn (local ++ "/" ++ local)
  putStrLn (twice local ++ twice greeting)
  putStrLn (describe greeting)
  putStrLn (describe codegen)
  putStrLn (describe dyn)
  putStrLn (label named ++ show (count named))
  case codegen of
    "rc2" => putStrLn "case rc2"
    _ => putStrLn "case other"
  putStrLn (if dyn == greeting then "dynamic equal" else "dynamic differs")
  putStrLn (orderReport (orderFolded, orderRuntime))
