module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises curl_easy_pause/curl_easy_upkeep -- both plain input-only
-- bindings, fully bound on both backends.
--
-- curl_easy_pause(3) is only meaningful called from inside a transfer
-- callback (e.g. CURLOPT_WRITEFUNCTION returning
-- CURL_WRITEFUNC_PAUSE) -- without one (see TODO.md's own callback
-- entry) there's no way to exercise real pausing here. Confirmed
-- directly, both through this binding and a bare C reproduction
-- outside Idris entirely, that calling it on a handle that either
-- hasn't started a transfer yet or has already finished one -- the
-- only two states reachable without a callback -- always returns
-- CURLE_BAD_FUNCTION_ARGUMENT (43): this is libcurl's own actual
-- behavior, not a binding bug. So this only confirms the binding
-- itself passes the right arguments through and gets the same result
-- C does, not that pausing itself works.

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

    result <- curlEasyPerform h
    putStrLn ("perform: " ++ show result)

    -- Expected to fail with CURLcode 43 outside a transfer callback --
    -- see this module's own header comment.
    pauseResult <- curlEasyPause h curlpause_CONT
    putStrLn ("pause(CONT) outside a callback: " ++ show pauseResult)

    MkCURLcode 0 <- curlEasyUpkeep h
        | c5 => putStrLn ("curl_easy_upkeep failed: " ++ show c5)
    putStrLn "upkeep ok"

    curlEasyCleanup h
    curlGlobalCleanup
