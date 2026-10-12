module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `chat` against tests/data/mock_api.py: a reply, a rejected key, and
-- a server that isn't there.

import System

import Network.WebAPI.AI.OpenAI
import Network.WebAPI.AI.Providers

main : IO ()
main = do
    [_, base] <- getArgs
        | _ => putStrLn "usage: TestWebAPIChat <base url>"
    let req = { maxTokens := Just 64 } (chatRequest "llama-3" [MkMessage User "ping"])
    Right r <- chat (llama (base ++ "/v1") (Just "test-key")) req
        | Left e => printLn e
    printLn (reply r)
    chat (llama (base ++ "/v1") (Just "wrong")) req >>= printLn . map reply
    chat (llama (base ++ "/v1") Nothing) req >>= printLn . map reply
    chat (llama "http://127.0.0.1:1/v1" Nothing) req >>= \case
        Left (TransportError _) => putStrLn "TransportError"
        other => printLn (map reply other)
