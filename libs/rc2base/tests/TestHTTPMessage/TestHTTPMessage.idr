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
  for_ [("from 0", 0), ("from 3 bytes before the CR", 20), ("from the CR", 23), ("after the CR", 24)] $ \(name, from) => do
    r <- headEnd req from
    putStrLn (name ++ ": " ++ show r)
  r <- headEnd "GET / HTTP/1.1\r\nHost: x\r\n\r" 0
  putStrLn ("incomplete: " ++ show r)
  putStrLn "--- parseHead ---"
  for_ [ ("plain", "GET /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5")
       , ("spaces around the value", "GET /a HTTP/1.1\r\nHost:   x  ")
       , ("space before the colon", "GET /a HTTP/1.1\r\nContent-Length : 5")
       , ("tab before the colon", "GET /a HTTP/1.1\r\nHost\t: x")
       , ("obsolete line fold", "GET /a HTTP/1.1\r\nHost: x\r\n folded")
       , ("no colon", "GET /a HTTP/1.1\r\nNoColon")
       , ("empty name", "GET /a HTTP/1.1\r\n: x")
       , ("no path", "GET\r\nHost: x")
       ] $ \(name, head) => do
    buf <- fromString (head ++ "\r\n\r\n")
    r <- parseHead buf (byteLength buf - 4)
    putStrLn (name ++ ": " ++ show r)
  putStrLn "--- growBuffer ---"
  small <- fromString "abcd"
  same <- growBuffer small 3 100
  putStrLn ("big enough: " ++ show (map byteLength same))
  bigger <- growBuffer small 10 100
  putStrLn ("to what is needed: " ++ show (map byteLength bigger))
  doubled <- growBuffer small 5 100
  putStrLn ("doubled: " ++ show (map byteLength doubled))
  capped <- growBuffer small 5 6
  putStrLn ("doubled, clamped to the cap: " ++ show (map byteLength capped))
  over <- growBuffer small 10 9
  putStrLn ("over the cap: " ++ show (map byteLength over))
  kept <- traverse (\b => toString b) bigger
  putStrLn ("old bytes kept: " ++ show (map (substr 0 4) kept))
