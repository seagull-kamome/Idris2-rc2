module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Body capture into a String and a Buffer through libc's
-- open_memstream, on a `file://` transfer; the same handle is captured
-- twice.

import Data.Buffer
import System

import Network.Curl.Raw
import Network.Curl.Types

main : IO ()
main = do
    [_, path] <- getArgs
        | _ => putStrLn "usage: TestCapture <file>"
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
    curlEasyPerformToString h >>= printLn
    Just (rc, buf) <- curlEasyPerformToBuffer h
        | Nothing => putStrLn "capture failed"
    printLn rc
    bufferData buf >>= printLn
    _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path ++ ".missing")
    curlEasyPerformToString h >>= printLn
    curlEasyCleanup h
    curlGlobalCleanup
