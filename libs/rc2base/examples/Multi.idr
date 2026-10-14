module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

partial
runOne : AnyPtr -> String -> IO AnyPtr
runOne multi url = do
    Just h <- curlEasyInit
        | Nothing => idris_crash "curl_easy_init failed"
    MkCURLcode 0 <- curlEasySetoptString h curlopt_URL url
        | c => idris_crash ("setopt URL failed: " ++ show c)
    MkCURLMcode 0 <- curlMultiAddHandle multi h
        | c => idris_crash ("curl_multi_add_handle failed: " ++ show c)
    pure h

||| Drains every currently-queued `CURLMSG_DONE` message, reporting
||| each one and removing/cleaning up its own easy handle. Loops
||| itself rather than reading just one message per `curlMultiPerform`
||| tick, since `curl_multi_info_read`'s own contract is "call this
||| repeatedly until it returns nothing", not "at most one message per
||| perform".
partial
drainMessages : AnyPtr -> IO ()
drainMessages multi = do
    Just (msg, h, result) <- curlMultiInfoRead multi
        | Nothing => pure ()
    when (msg == curlmsg_DONE) $
        putStrLn ("transfer done: " ++ show result)
    MkCURLMcode 0 <- curlMultiRemoveHandle multi h
        | c => idris_crash ("curl_multi_remove_handle failed: " ++ show c)
    curlEasyCleanup h
    drainMessages multi

partial
loop : AnyPtr -> IO ()
loop multi = do
    Right running <- curlMultiPerform multi
        | Left c => idris_crash ("curl_multi_perform failed: " ++ curlMultiStrerror c)
    drainMessages multi
    when (running > 0) $ do
        Right _ <- curlMultiWait multi 1000
            | Left c => idris_crash ("curl_multi_wait failed: " ++ curlMultiStrerror c)
        loop multi

partial
main : IO ()
main = do
    MkCURLcode 0 <- curlGlobalInit
        | c1 => putStrLn ("curl_global_init failed: " ++ show c1)
    Just multi <- curlMultiInit
        | Nothing => putStrLn "curl_multi_init failed"

    _ <- runOne multi "http://example.com"
    _ <- runOne multi "http://example.org"

    loop multi

    MkCURLMcode 0 <- curlMultiCleanup multi
        | c2 => putStrLn ("curl_multi_cleanup failed: " ++ curlMultiStrerror c2)
    curlGlobalCleanup
