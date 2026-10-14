module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- End-to-end smoke check: init curl, GET a URL, report the CURLcode.
-- Not an automated test (no expected-output diffing); see
-- the library's tests (tests/TestCurl).

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptLong h curlopt_VERBOSE 1
        | c2 => putStrLn ("setopt VERBOSE failed: " ++ show c2)
    MkCURLcode 0 <- curlEasySetoptString h curlopt_URL "http://example.com"
        | c3 => putStrLn ("setopt URL failed: " ++ show c3)
    result <- curlEasyPerform h
    let msg = curlEasyStrerror result
    putStrLn ("curl_easy_perform result: " ++ show result ++ " (" ++ msg ++ ")")
    curlEasyCleanup h
    curlGlobalCleanup
