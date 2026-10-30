module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises curl_easy_escape/unescape, curl_version and the curl_url_*
-- URL API, all without network access (curl_url_get is in UrlGet.idr).

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    putStrLn ("curl_version: " ++ !curlVersion)

    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"

    Just escaped <- curlEasyEscape h "a b/c?d"
        | Nothing => putStrLn "curl_easy_escape failed"
    putStrLn ("escaped: " ++ escaped)
    Just unescaped <- curlEasyUnescape h escaped
        | Nothing => putStrLn "curl_easy_unescape failed"
    putStrLn ("unescaped: " ++ unescaped)

    curlEasyCleanup h
    curlGlobalCleanup

    Just u <- curlUrl
        | Nothing => putStrLn "curl_url failed"
    MkCURLUcode 0 <- curlUrlSet u curlupart_URL "https://example.com/path?q=1" 0
        | e1 => putStrLn ("curl_url_set failed: " ++ curlUrlStrerror e1)
    Just u2 <- curlUrlDup u
        | Nothing => putStrLn "curl_url_dup failed"
    curlUrlCleanup u2
    curlUrlCleanup u
