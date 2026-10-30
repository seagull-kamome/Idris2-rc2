module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Server with the routes of OldServer.idr (and /sleep, which the
-- old server has no way to do), for bench.sh. Usage: NewServer PORT THREADS
-- (0 threads is the single-threaded scheduler).

import Control.Task
import Data.Buffer
import Data.String
import Network.Async.HTTP.Server
import System
import System.Posix.Errno

%default covering

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
  [_, p, t] <- getArgs
    | _ => putStrLn "usage: NewServer PORT THREADS"
  big <- blob 65536
  let handler : Handler
      handler req = case req.path of
        "/hello" => liftIO (text 200 "hello\n")
        "/echo" => liftIO (text 200 "len=\{show (byteLength req.body)}\n")
        "/work" => liftIO (text 200 (show (work (300000 + cast (length req.path))) ++ "\n"))
        "/big" => pure (bytes 200 "application/octet-stream" big)
        "/sleep" => sleepFor 50 *> liftIO (text 200 "slept\n")
        _ => liftIO (notFound "no\n")
  ignore (runServer (cast (the Integer (cast t))) (serve (cast (the Integer (cast p))) handler))
