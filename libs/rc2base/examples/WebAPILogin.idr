module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Google OAuth login for Gemini: saves the token to gemini-token.json,
-- which `WebAPIChat gemini-oauth` then uses and refreshes. Needs
-- GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET, see
-- doc/webapi-getting-started.md (in libs/rc2base).

import Network.HTTP.Client.Curl
import System

import Network.HTTP.Client.WebAPI.AI.Providers
import Network.HTTP.Client.WebAPI.Auth.OAuth2

partial
main : IO ()
main = do
    Just i <- getEnv "GOOGLE_CLIENT_ID"     | Nothing => putStrLn "GOOGLE_CLIENT_ID is not set"
    Just s <- getEnv "GOOGLE_CLIENT_SECRET" | Nothing => putStrLn "GOOGLE_CLIENT_SECRET is not set"
    Right t <- login curlClient (google i s geminiScopes)
        | Left e => putStrLn ("login failed: " ++ e)
    Right () <- saveToken "gemini-token.json" t
        | Left e => putStrLn e
    putStrLn "Saved gemini-token.json"
