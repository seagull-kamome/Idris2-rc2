module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The old callback server (Network.HTTP.Server) with the routes of NewServer.idr,
-- for bench.sh. Usage: OldServer PORT

import Data.Buffer
import Network.HTTP.Server
import System

%default covering

-- A loop that costs CPU time (the iteration count depends on the request, so it is not folded).
work : Int -> Int
work n = go 0 0
  where
    go : Int -> Int -> Int
    go i acc = if i >= n then acc else go (i + 1) ((acc * 31 + i) `mod` 1000003)

blob : Int -> IO Buffer
blob n = do
  Just b <- newBuffer n
    | Nothing => assert_total (idris_crash "newBuffer failed")
  pure b

main : IO ()
main = do
  [_, p] <- getArgs
    | _ => putStrLn "usage: OldServer PORT"
  big <- blob 65536
  let handler : Handler
      handler req respond = case req.path of
        "/hello" => respond !(text 200 "hello\n")
        "/echo" => respond !(text 200 "len=\{show (byteLength req.body)}\n")
        "/work" => respond !(text 200 (show (work (300000 + cast (length req.path))) ++ "\n"))
        "/big" => respond (bytes 200 "application/octet-stream" big)
        _ => respond !(notFound "no\n")
  serve (cast (the Integer (cast p))) handler
