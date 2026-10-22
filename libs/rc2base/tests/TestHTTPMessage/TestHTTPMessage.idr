module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Message.bodyLength: the headers that frame a request's body, and
-- the ones that must not be trusted to (they would hide the body from the
-- parser, or make it read past the data). And Route's FromSegment Int, which
-- must not wrap around on a number that does not fit.

import Data.Buffer
import Network.HTTP.Message
import Network.HTTP.Route

%default covering

cl : String -> List (String, String)
cl v = [("content-length", v)]

conn : String -> List (String, String)
conn v = [("connection", v)]

-- `s` in a buffer, and where the head ends when looking from `from` on.
headEnd : String -> (from : Int) -> IO (Maybe Int)
headEnd s from = do
  buf <- fromString s
  findHeadEndFrom buf from (byteLength buf)

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
  putStrLn "--- connectionClose ---"
  traverse_ (\(name, hdrs) => putStrLn (name ++ ": " ++ show (connectionClose hdrs)))
    [ ("none", [])
    , ("close", conn "close")
    , ("Close, spaces", conn "  Close ")
    , ("keep-alive", conn "keep-alive")
    , ("keep-alive, close", conn "keep-alive, close")
    , ("upgrade", conn "upgrade")
    ]
  putStrLn "--- responseHead ---"
  body <- fromString "hello"
  traverse_ (\status => putStrLn (show status ++ ": " ++ show (responseHead (MkResponse status [("X", "1")] body) 5)))
    [200, 100, 204, 304, 404]
  putStrLn "--- findHeadEndFrom ---"
  let req = "GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY"
  traverse_ (\(name, from) => headEnd req from >>= \r => putStrLn (name ++ ": " ++ show r))
    [("from 0", 0), ("from 3 bytes before the CR", 20), ("from the CR", 23), ("after the CR", 24)]
  r <- headEnd "GET / HTTP/1.1\r\nHost: x\r\n\r" 0
  putStrLn ("incomplete: " ++ show r)
