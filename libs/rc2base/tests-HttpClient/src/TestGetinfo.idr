module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- One `file://` transfer, then every getinfo cell type: long, string,
-- double, off_t, socket and slist, plus a getinfo error code.

import Data.String
import System

import Network.Curl.Raw
import Network.Curl.Types

main : IO ()
main = do
    [_, path] <- getArgs
        | _ => putStrLn "usage: TestGetinfo <file>"
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
    rc <- curlEasyPerform h
    printLn rc
    curlEasyGetinfoLong h curlinfo_RESPONSE_CODE >>= printLn
    url <- curlEasyGetinfoString h curlinfo_EFFECTIVE_URL
    printLn (map (isSuffixOf "/tests/data/hello.txt") url)
    curlEasyGetinfoOfft h curlinfo_SIZE_DOWNLOAD_T >>= printLn
    t <- curlEasyGetinfoDouble h curlinfo_TOTAL_TIME
    printLn (map (>= 0) t)
    curlEasyGetinfoSocket h curlinfo_ACTIVESOCKET >>= printLn
    Right cookies <- curlEasyGetinfoSlist h curlinfo_COOKIELIST
        | Left c => printLn c
    curlSlistToList cookies >>= printLn
    curlSlistFreeAll cookies
    curlEasyGetinfoLong h (MkCURLINFO 0) >>= printLn
    list <- curlSlistAppend curlSlistEmpty "one"
    list <- curlSlistAppend list "two"
    curlSlistToList list >>= printLn
    curlSlistFreeAll list
    curlEasyCleanup h
    curlGlobalCleanup
