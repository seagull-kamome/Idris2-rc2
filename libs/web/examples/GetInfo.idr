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

    code <- curlEasyGetinfoLong h curlinfo_RESPONSE_CODE
    url <- curlEasyGetinfoString h curlinfo_EFFECTIVE_URL
    ctype <- curlEasyGetinfoString h curlinfo_CONTENT_TYPE
    totalTime <- curlEasyGetinfoDouble h curlinfo_TOTAL_TIME
    activeSocket <- curlEasyGetinfoSocket h curlinfo_ACTIVESOCKET
    putStrLn ("response code: " ++ either show show code)
    putStrLn ("effective url: " ++ either show id url)
    putStrLn ("content type: " ++ either show id ctype)
    putStrLn ("total time is non-negative: " ++ either show (show . (>= 0)) totalTime)
    putStrLn ("active socket is valid fd: " ++ either show (show . (>= 0)) activeSocket)

    -- No cookies are set on this handle: this exercises the
    -- CURLINFO_SLIST read path, not cookie content.
    Right cookieSlist <- curlEasyGetinfoSlist h curlinfo_COOKIELIST
        | Left c4 => putStrLn ("getinfo COOKIELIST failed: " ++ show c4)
    cookies <- curlSlistToList cookieSlist
    putStrLn ("cookie list: " ++ show cookies)
    curlSlistFreeAll cookieSlist

    curlEasyCleanup h
    curlGlobalCleanup
