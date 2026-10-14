module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises the curl_share_* and curl_mime_* bindings.

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)

    -- Share: a DNS cache shared across two easy handles fetching the
    -- same host. No way to observe the caching itself from here, but
    -- exercises curl_share_init/setopt/curl_easy_setopt(CURLOPT_SHARE)
    -- end to end without erroring.
    Just sh <- curlShareInit
        | Nothing => putStrLn "curl_share_init failed"
    MkCURLSHcode 0 <- curlShareSetopt sh True curllockdata_DNS
        | e1 => putStrLn ("curl_share_setopt failed: " ++ curlShareStrerror e1)

    Just h1 <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptPointer h1 curlopt_SHARE sh
        | c2 => putStrLn ("setopt SHARE failed: " ++ show c2)
    MkCURLcode 0 <- curlEasySetoptString h1 curlopt_URL "http://example.com"
        | c3 => putStrLn ("setopt URL failed: " ++ show c3)
    result1 <- curlEasyPerform h1
    putStrLn ("first request: " ++ show result1)
    curlEasyCleanup h1

    Just h2 <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptPointer h2 curlopt_SHARE sh
        | c4 => putStrLn ("setopt SHARE failed: " ++ show c4)
    MkCURLcode 0 <- curlEasySetoptString h2 curlopt_URL "http://example.org"
        | c5 => putStrLn ("setopt URL failed: " ++ show c5)
    result2 <- curlEasyPerform h2
    putStrLn ("second request (shared DNS cache): " ++ show result2)
    curlEasyCleanup h2

    MkCURLSHcode 0 <- curlShareCleanup sh
        | e2 => putStrLn ("curl_share_cleanup failed: " ++ curlShareStrerror e2)

    -- Mime: a two-field multipart form, attached to a POST. No echo
    -- server to verify field contents against, but exercises
    -- curl_mime_init/addpart/name/data/filename/type and
    -- CURLOPT_MIMEPOST end to end without erroring.
    Just h3 <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    Just mime <- curlMimeInit h3
        | Nothing => putStrLn "curl_mime_init failed"

    Just part1 <- curlMimeAddpart mime
        | Nothing => putStrLn "curl_mime_addpart failed"
    MkCURLcode 0 <- curlMimeName part1 "field1"
        | c6 => putStrLn ("curl_mime_name failed: " ++ show c6)
    MkCURLcode 0 <- curlMimeData part1 "hello"
        | c7 => putStrLn ("curl_mime_data failed: " ++ show c7)

    Just part2 <- curlMimeAddpart mime
        | Nothing => putStrLn "curl_mime_addpart failed"
    MkCURLcode 0 <- curlMimeName part2 "field2"
        | c8 => putStrLn ("curl_mime_name failed: " ++ show c8)
    MkCURLcode 0 <- curlMimeType part2 "text/plain"
        | c9 => putStrLn ("curl_mime_type failed: " ++ show c9)
    MkCURLcode 0 <- curlMimeData part2 "world"
        | c10 => putStrLn ("curl_mime_data failed: " ++ show c10)

    MkCURLcode 0 <- curlEasySetoptPointer h3 curlopt_MIMEPOST mime
        | c11 => putStrLn ("setopt MIMEPOST failed: " ++ show c11)
    MkCURLcode 0 <- curlEasySetoptString h3 curlopt_URL "http://example.com"
        | c12 => putStrLn ("setopt URL failed: " ++ show c12)
    result3 <- curlEasyPerform h3
    putStrLn ("mime POST: " ++ show result3)

    curlEasyCleanup h3
    curlGlobalCleanup
