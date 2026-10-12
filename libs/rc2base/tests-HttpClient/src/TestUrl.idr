module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Escape/unescape, the URL API and the strerror bindings: everything
-- here is local to libcurl, no transfer.

import Network.Curl.Raw
import Network.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    curlEasyEscape h "a b/c?d" >>= printLn
    curlEasyUnescape h "a%20b%2Fc%3Fd" >>= printLn
    Just u <- curlUrl
        | Nothing => putStrLn "curl_url failed"
    rc <- curlUrlSet u curlupart_URL "https://user@example.com:8080/p/q?x=1#frag" 0
    printLn (rc == curlue_OK)
    for_ [ curlupart_SCHEME, curlupart_USER, curlupart_PASSWORD, curlupart_HOST
         , curlupart_PORT, curlupart_PATH, curlupart_QUERY, curlupart_FRAGMENT ] $ \p =>
        curlUrlGet u p 0 >>= printLn
    Just u2 <- curlUrlDup u
        | Nothing => putStrLn "curl_url_dup failed"
    curlUrlGet u2 curlupart_URL 0 >>= printLn
    bad <- curlUrlSet u2 curlupart_URL "https://[::1" 0
    putStrLn (curlUrlStrerror bad)
    curlUrlCleanup u2
    curlUrlCleanup u
    putStrLn (curlEasyStrerror (MkCURLcode 6))
    putStrLn (curlMultiStrerror (MkCURLMcode 1))
    putStrLn (curlShareStrerror (MkCURLSHcode 1))
    curlEasyCleanup h
    curlGlobalCleanup
