module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Message.framing: the headers that frame a request's body, and
-- the ones that must not be trusted to (they would hide the body from the
-- parser, or make it read past the data). And Route's FromSegment Int, which
-- must not wrap around on a number that does not fit.

import Data.Buffer
import Network.HTTP.Message
import Network.HTTP.Route

%default covering

cl : String -> List (String, String)
cl v = [("content-length", v)]

te : String -> List (String, String)
te v = [("transfer-encoding", v)]

conn : String -> List (String, String)
conn v = [("connection", v)]

-- `s` in a buffer, and where the head ends when looking from `from` on.
headEnd : String -> (from : Int) -> IO (Maybe Int)
headEnd s from = do
  buf <- fromString s
  findHeadEndFrom buf from (byteLength buf)

ex : String -> List (String, String)
ex v = [("expect", v)]

-- What a scan of `s` finds, with a limit on the bytes of the chunks, and the
-- bytes it gives.
scanOf : (String, String, Int) -> IO ()
scanOf (name, s, limit) = do
  buf <- fromString s
  r <- scanChunks Nothing buf (byteLength buf) limit (MkChunkMark 0 0)
  line <- case r of
    ChunksEnd end size => do
      out <- joinChunks buf 0 end size
      text <- toString out
      pure ("end " ++ show end ++ " size " ++ show size ++ " " ++ show text)
    ChunksMore m => pure ("more from " ++ show m.at ++ " after " ++ show m.decoded)
    ChunksBad => pure "bad"
    ChunksTooLarge => pure "too large"
  putStrLn (name ++ ": " ++ line)

-- The scan of `s`, given first one byte, then two, and so on, each time from the mark
-- of the one before.
pieceWise : String -> IO ()
pieceWise s = do
  buf <- fromString s
  go buf 1 (MkChunkMark 0 0)
  where
    go : Buffer -> Int -> ChunkMark -> IO ()
    go buf n mark =
      if n > byteLength buf then putStrLn "never ended" else do
        r <- scanChunks Nothing buf n 1000 mark
        case r of
          ChunksMore mark' => go buf (n + 1) mark'
          ChunksEnd end size => putStrLn ("ends with " ++ show n ++ " bytes: " ++ show end ++ ", " ++ show size)
          _ => putStrLn "failed"

main : IO ()
main = do
  putStrLn "--- framing ---"
  traverse_ (\(name, hdrs) => putStrLn (name ++ ": " ++ show (framing hdrs)))
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
    , ("chunked", te "chunked")
    , ("chunked, any case, spaces", te "  Chunked ")
    , ("chunked, vertical tab", te "chunked\x0b")
    , ("chunked and length", cl "5" ++ te "chunked")
    , ("gzip then chunked", te "gzip, chunked")
    , ("two headers", te "gzip" ++ te "chunked")
    , ("chunked then gzip", te "chunked, gzip")
    , ("gzip", te "gzip")
    , ("chunked twice", te "chunked, chunked")
    , ("empty", te "")
    , ("empty items", te " , chunked,")
    ]
  putStrLn "--- expectation ---"
  traverse_ (\(name, hdrs) => putStrLn (name ++ ": " ++ show (expectation hdrs)))
    [ ("none", [])
    , ("100-continue", ex "100-continue")
    , ("any case, spaces", ex "  100-Continue ")
    , ("twice", ex "100-continue" ++ ex "100-continue")
    , ("other", ex "200-ok")
    , ("mixed", ex "100-continue" ++ ex "x")
    ]
  putStrLn "--- chunked bodies ---"
  traverse_ scanOf
    [ ("one chunk", "3\r\nabc\r\n0\r\n\r\n", 1000)
    , ("extension, hex size", "A;x=y\r\n0123456789\r\n0\r\n\r\n", 1000)
    , ("trailer", "1\r\na\r\n0\r\nT: v\r\nU: w\r\n\r\n", 1000)
    , ("followed by more", "1\r\na\r\n0\r\n\r\nGET /", 1000)
    , ("empty", "0\r\n\r\n", 1000)
    , ("leading zeros", "0000000003\r\nabc\r\n0\r\n\r\n", 1000)
    , ("no bytes", "", 1000)
    , ("half a size line", "3\r", 1000)
    , ("half the data", "3\r\nab", 1000)
    , ("no last chunk", "3\r\nabc\r\n", 1000)
    , ("no end of trailers", "0\r\nT: v\r\n", 1000)
    , ("not hex", "g\r\n", 1000)
    , ("no size", "\r\n", 1000)
    , ("space in size", "3 \r\nabc\r\n0\r\n\r\n", 1000)
    , ("bare LF", "3\nabc\r\n0\r\n\r\n", 1000)
    , ("no CRLF after data", "3\r\nabcXY0\r\n\r\n", 1000)
    , ("control character in extension", "3;\x01\r\nabc\r\n0\r\n\r\n", 1000)
    , ("trailer without colon", "0\r\nT\r\n\r\n", 1000)
    , ("over the limit, data not there", "10\r\n", 15)
    , ("over the limit, in two", "8\r\n12345678\r\n8\r\n", 15)
    , ("size that does not fit", "ffffffffffffffffffffffff\r\n", 1000)
    ]
  putStrLn "--- chunked bodies, a piece at a time ---"
  pieceWise "3\r\nabc\r\n4;e\r\ndefg\r\n0\r\nT: v\r\n\r\n"
  putStrLn "--- decodedHeaders ---"
  putStrLn (show (decodedHeaders 7 [("host", "t"), ("transfer-encoding", "chunked")]))
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
  putStrLn "--- connectionKeepAlive ---"
  traverse_ (\(name, hdrs) => putStrLn (name ++ ": " ++ show (connectionKeepAlive hdrs)))
    [ ("none", [])
    , ("close", conn "close")
    , ("Keep-Alive, spaces", conn "  Keep-Alive ")
    , ("close, keep-alive", conn "close, keep-alive")
    ]
  putStrLn "--- responseHead ---"
  body <- fromString "hello"
  traverse_ (\status => putStrLn (show status ++ ": " ++ show (responseHead (MkResponse status [("X", "1")] body))))
    [200, 100, 204, 304, 404, 505]
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
