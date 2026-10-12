module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Body capture into a TextBuffer (rc2 only: Data.TextBuffer is an rc2
-- runtime type).

import Data.TextBuffer
import System

import Network.Curl.Raw
import Network.Curl.TextBuffer
import Network.Curl.Types

main : IO ()
main = do
    [_, path] <- getArgs
        | _ => putStrLn "usage: TestCaptureText <file>"
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
    Just (rc, txt) <- curlEasyPerformToTextBuffer h
        | Nothing => putStrLn "capture failed"
    printLn rc
    printLn (toString txt)
    curlEasyCleanup h
    curlGlobalCleanup
