module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Curl.Fetch against verify.sh's local HTTP server: status,
-- header names and body, as String and bytes, plus fetchText's
-- HttpError for a missing file.

import Data.Buffer
import System

import Network.Curl.Fetch

main : IO ()
main = do
    [_, base] <- getArgs
        | _ => putStrLn "usage: TestFetch <base url>"
    Right r <- fetch (get (base ++ "/hello.txt"))
        | Left e => printLn e
    printLn (r.status, map fst r.headers, r.body)
    Right b <- fetchBytes (get (base ++ "/hello.txt"))
        | Left e => printLn e
    bufferData b.body >>= printLn
    fetchText (base ++ "/hello.txt") >>= printLn
    fetchText (base ++ "/missing.txt") >>= printLn
