module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

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

    MkCURLcode 0 <- curlEasyPerform h
        | c3 => putStrLn ("curl_easy_perform failed: " ++ show c3)

    downloadSize <- curlEasyGetinfoOfft h curlinfo_SIZE_DOWNLOAD_T
    putStrLn ("download size (off_t): " ++ either show show downloadSize)

    curlEasyCleanup h
    curlGlobalCleanup
