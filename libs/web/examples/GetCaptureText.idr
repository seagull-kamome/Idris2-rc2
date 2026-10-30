module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- rc2-only: exercises curlEasyPerformToTextBuffer; Data.TextBuffer is an
-- rc2 runtime type.

import Data.TextBuffer

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.TextBuffer
import Network.HTTP.Client.Curl.Types

main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptString h curlopt_URL "http://example.com"
        | c2 => putStrLn ("setopt URL failed: " ++ show c2)

    Just (result, t) <- curlEasyPerformToTextBuffer h
        | Nothing => putStrLn "curlEasyPerformToTextBuffer failed"
    putStrLn ("TextBuffer length (codepoints): " ++ show (Data.TextBuffer.length t))
    putStrLn ("TextBuffer round-trip: " ++ toString t)

    let msg = curlEasyStrerror result
    putStrLn ("curl_easy_perform result: " ++ show result ++ " (" ++ msg ++ ")")

    curlEasyCleanup h
    curlGlobalCleanup
