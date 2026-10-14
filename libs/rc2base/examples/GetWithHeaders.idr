module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises curl_slist (a custom request header), curl_easy_reset and
-- curl_easy_duphandle.

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"

    let headers = curlSlistEmpty
    headers <- curlSlistAppend headers "X-Idris2-Curl: phase1"

    MkCURLcode 0 <- curlEasySetoptPointer h curlopt_HTTPHEADER headers
        | c2 => putStrLn ("setopt HTTPHEADER failed: " ++ show c2)
    MkCURLcode 0 <- curlEasySetoptString h curlopt_URL "http://example.com"
        | c3 => putStrLn ("setopt URL failed: " ++ show c3)

    result <- curlEasyPerform h
    let msg = curlEasyStrerror result
    putStrLn ("curl_easy_perform result: " ++ show result ++ " (" ++ msg ++ ")")

    curlEasyReset h
    Just h2 <- curlEasyDuphandle h
        | Nothing => putStrLn "curl_easy_duphandle failed"
    curlEasyCleanup h2

    curlSlistFreeAll headers
    curlEasyCleanup h
    curlGlobalCleanup
