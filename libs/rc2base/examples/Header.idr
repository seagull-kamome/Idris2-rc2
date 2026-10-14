module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

partial
listHeaders : AnyPtr -> AnyPtr -> IO ()
listHeaders h prev = do
    Just (next, name, value) <- curlEasyNextheader h curlh_HEADER 0 prev
        | Nothing => pure ()
    putStrLn (name ++ ": " ++ value)
    listHeaders h next

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

    Just (contentType, ctValue) <- curlEasyHeader h "content-type" curlh_HEADER 0
        | Nothing => putStrLn "content-type header not found"
    putStrLn ("looked up directly: " ++ contentType ++ ": " ++ ctValue)

    putStrLn "all headers via nextheader:"
    listHeaders h curlSlistEmpty

    curlEasyCleanup h
    curlGlobalCleanup
