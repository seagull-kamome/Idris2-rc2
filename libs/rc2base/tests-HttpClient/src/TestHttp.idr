module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A transfer against verify.sh's local HTTP server: the header API
-- (curl_easy_header's struct out-parameter, curl_easy_nextheader's
-- iteration) and the status code.

import System

import Network.Curl.Raw
import Network.Curl.Types

partial
names : AnyPtr -> AnyPtr -> IO (List String)
names h prev = do
    Just (next, name, _) <- curlEasyNextheader h curlh_HEADER (-1) prev
        | Nothing => pure []
    (name ::) <$> names h next

partial
main : IO ()
main = do
    [_, url] <- getArgs
        | _ => putStrLn "usage: TestHttp <url>"
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    _ <- curlEasySetoptString h curlopt_URL url
    _ <- curlEasySetoptLong h curlopt_NOBODY 1
    curlEasyPerform h >>= printLn
    curlEasyGetinfoLong h curlinfo_RESPONSE_CODE >>= printLn
    curlEasyHeader h "content-length" curlh_HEADER (-1) >>= printLn
    curlEasyHeader h "x-absent" curlh_HEADER (-1) >>= printLn
    names h curlSlistEmpty >>= printLn
    curlEasyCleanup h
    curlGlobalCleanup
