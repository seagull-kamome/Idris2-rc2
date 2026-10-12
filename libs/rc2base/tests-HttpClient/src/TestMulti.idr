module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Two `file://` transfers driven through the multi interface: the
-- running-count and message-queue out-parameters and the CURLMsg view.
-- Completion order is up to libcurl, so only membership is printed.

import System

import Network.Curl.Raw
import Network.Curl.Types

partial
drain : AnyPtr -> IO (List Int)
drain m = do
    Just (msg, h, MkCURLcode result) <- curlMultiInfoRead m
        | Nothing => pure []
    _ <- curlMultiRemoveHandle m h
    curlEasyCleanup h
    rest <- drain m
    pure $ if msg == curlmsg_DONE then result :: rest else rest

partial
loop : AnyPtr -> IO (List Int)
loop m = do
    Right running <- curlMultiPerform m
        | Left c => do putStrLn ("curl_multi_perform failed: " ++ curlMultiStrerror c)
                       pure []
    done <- drain m
    if running == 0 then pure done else do
        Right _ <- curlMultiWait m 1000
            | Left c => do putStrLn ("curl_multi_wait failed: " ++ curlMultiStrerror c)
                           pure done
        (done ++) <$> loop m

partial
main : IO ()
main = do
    [_, path] <- getArgs
        | _ => putStrLn "usage: TestMulti <file>"
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just m <- curlMultiInit
        | Nothing => putStrLn "curl_multi_init failed"
    for_ [path, path ++ ".missing"] $ \p => do
        Just h <- curlEasyInit
            | Nothing => putStrLn "curl_easy_init failed"
        _ <- curlEasySetoptLong h curlopt_NOBODY 1
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ p)
        curlMultiAddHandle m h >>= printLn
    done <- loop m
    printLn (length done, elem 0 done, elem 37 done)
    curlMultiCleanup m >>= printLn
    curlGlobalCleanup
