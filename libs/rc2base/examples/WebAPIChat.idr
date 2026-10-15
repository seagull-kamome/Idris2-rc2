module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- One chat completion against the service named on the command line.
-- Keys and the Gemini OAuth setup: doc/webapi-getting-started.md.
--
--   WebAPIChat claude <model> <prompt>                  (ANTHROPIC_API_KEY)
--   WebAPIChat gemini <model> <prompt>                  (GEMINI_API_KEY)
--   WebAPIChat gemini-oauth <model> <prompt>            (after WebAPILogin)
--   WebAPIChat llama <base url> <model> <prompt>        (LLAMA_API_KEY, optional)

import Network.HTTP.Client.Curl
import Data.Maybe
import System

import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.Providers
import Network.HTTP.Client.WebAPI.Auth.OAuth2

partial
endpoint : List String -> IO (Either String (Endpoint, String, String))
endpoint ["claude", m, p] = map (\e => (e, m, p)) <$> claudeFromEnv
endpoint ["gemini", m, p] = map (\e => (e, m, p)) <$> geminiFromEnv
endpoint ["gemini-oauth", m, p] = do
    Just i  <- getEnv "GOOGLE_CLIENT_ID"     | Nothing => pure (Left "GOOGLE_CLIENT_ID is not set")
    Just s  <- getEnv "GOOGLE_CLIENT_SECRET" | Nothing => pure (Left "GOOGLE_CLIENT_SECRET is not set")
    Just pj <- getEnv "GOOGLE_CLOUD_PROJECT" | Nothing => pure (Left "GOOGLE_CLOUD_PROJECT is not set")
    pure (Right (geminiOAuth curlClient (google i s geminiScopes) "gemini-token.json" pj, m, p))
endpoint ["llama", url, m, p] = do
    key <- getEnv "LLAMA_API_KEY"
    pure (Right (llama url key, m, p))
endpoint _ = pure (Left "usage: WebAPIChat (claude|gemini|gemini-oauth) <model> <prompt> | llama <base url> <model> <prompt>")

partial
main : IO ()
main = do
    (_ :: args) <- getArgs
        | [] => putStrLn "no program name"
    Right (ep, model, prompt) <- endpoint args
        | Left e => putStrLn e
    Right r <- chat curlClient ep ({ maxTokens := Just 512 } (chatRequest model [MkMessage User prompt]))
        | Left e => printLn e
    putStrLn (fromMaybe "(no reply)" (reply r))
