module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Message.bodyLength: the headers that frame a request's body, and
-- the ones that must not be trusted to (they would hide the body from the
-- parser, or make it read past the data). And Route's FromSegment Int, which
-- must not wrap around on a number that does not fit.

import Network.HTTP.Message
import Network.HTTP.Route

%default covering

cl : String -> List (String, String)
cl v = [("content-length", v)]

main : IO ()
main = do
  putStrLn "--- bodyLength ---"
  traverse_ (\(name, hdrs) => putStrLn (name ++ ": " ++ show (bodyLength hdrs)))
    [ ("none", [])
    , ("zero", cl "0")
    , ("plain", cl "259")
    , ("18 digits", cl "999999999999999999")
    , ("19 digits", cl "1000000000000000000")
    , ("wraps to 3", cl "18446744073709551619")
    , ("wraps negative", cl "18446744073709551000")
    , ("max int", cl "9223372036854775807")
    , ("not a number", cl "abc")
    , ("negative", cl "-5")
    , ("plus sign", cl "+5")
    , ("empty", cl "")
    , ("two equal", cl "5" ++ cl "5")
    , ("two different", cl "5" ++ cl "6")
    , ("chunked", [("transfer-encoding", "chunked")])
    , ("chunked and length", cl "5" ++ [("transfer-encoding", "chunked")])
    ]
  putStrLn "--- FromSegment Int ---"
  traverse_ (\seg => putStrLn (seg ++ ": " ++ show (fromSegment {ty = Int} seg)))
    ["7", "-7", "9223372036854775807", "9223372036854775808", "18446744073709551617", "x"]
