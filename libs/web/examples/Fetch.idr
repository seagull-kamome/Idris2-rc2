module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Network.HTTP.Client.Curl (fetch/fetchBytes/fetchText/get/post).
-- Needs outbound network access, like examples/Get.idr.

import Data.Buffer
import Data.String

import Network.HTTP.Client.Curl

main : IO ()
main = do
    Right resp <- fetch curlClient (get "http://example.com")
        | Left err => putStrLn ("fetch failed: " ++ show err)
    putStrLn ("status: " ++ show resp.status)
    putStrLn ("header count > 0: " ++ show (length resp.headers > 0))
    putStrLn ("body length: " ++ show (length resp.body))

    Right bytesResp <- fetchBytes curlClient (get "http://example.com")
        | Left err => putStrLn ("fetchBytes failed: " ++ show err)
    bufSize <- rawSize bytesResp.body
    putStrLn ("bytes status: " ++ show bytesResp.status ++ ", size: " ++ show bufSize)

    Right text <- fetchText curlClient "http://example.com"
        | Left err => putStrLn ("fetchText failed: " ++ show err)
    putStrLn ("fetchText length: " ++ show (length text))

    -- A GET to a path that doesn't exist -- still `Right`, a real
    -- HTTP exchange, just not a 2xx (see FetchError's own doc comment
    -- on why fetch itself never folds this into Left).
    Right notFound <- fetch curlClient (get "http://example.com/does-not-exist")
        | Left err => putStrLn ("fetch curlClient (404) failed: " ++ show err)
    putStrLn ("404 status via fetch: " ++ show notFound.status)

    -- Same request via fetchText -- folds the non-2xx into Left.
    Left err <- fetchText curlClient "http://example.com/does-not-exist"
        | Right _ => putStrLn "fetchText (404): unexpectedly got Right"
    putStrLn ("404 status via fetchText: " ++ show err)

    -- POST with a body -- httpbin.org's own /post endpoint echoes the
    -- request body back under "data" in its JSON response.
    Right posted <- fetch curlClient (post "https://httpbin.org/post" "hello-from-fetch")
        | Left err => putStrLn ("post failed: " ++ show err)
    putStrLn ("post status: " ++ show posted.status)
    putStrLn ("post echoed body: " ++ show (isInfixOf "hello-from-fetch" posted.body))
