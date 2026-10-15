module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Captures a response body into a Buffer and a String without
-- CURLOPT_WRITEFUNCTION (doc/http-client.md, "Body capture").

import Data.Buffer

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptString h curlopt_URL "http://example.com"
        | c2 => putStrLn ("setopt URL failed: " ++ show c2)

    Just (result, buf) <- curlEasyPerformToBuffer h
        | Nothing => putStrLn "curlEasyPerformToBuffer failed"
    bufSize <- rawSize buf
    putStrLn ("Buffer rawSize: " ++ show bufSize)

    Just (_, s) <- curlEasyPerformToString h
        | Nothing => putStrLn "curlEasyPerformToString failed"
    putStrLn ("String length (bytes): " ++ show (length s))
    putStrLn ("String content: " ++ s)

    let msg = curlEasyStrerror result
    putStrLn ("curl_easy_perform result: " ++ show result ++ " (" ++ msg ++ ")")

    curlEasyCleanup h
    curlGlobalCleanup
