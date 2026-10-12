module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `login` against tests/data/mock_api.py, then the token file: saved,
-- used as is while valid, refreshed once expired. TestWebAPILogin.sh
-- plays the browser.

import System

import Network.WebAPI.Auth.OAuth2

main : IO ()
main = do
    [_, base, file] <- getArgs
        | _ => putStrLn "usage: TestWebAPILogin <base url> <token file>"
    let c = MkClient (base ++ "/auth") (base ++ "/token") "cid" (Just "sec") ["s1", "s2"] []
    Right t <- login c
        | Left e => putStrLn ("login: " ++ e)
    printLn (t.accessToken, t.refreshToken)
    Right () <- saveToken file t
        | Left e => putStrLn e
    accessToken c file >>= printLn
    Right () <- saveToken file ({ expiresAt := 0 } t)
        | Left e => putStrLn e
    accessToken c file >>= printLn
    map (\t' => (t'.accessToken, t'.refreshToken)) <$> loadToken file >>= printLn
    Right () <- saveToken file ({ expiresAt := 0, refreshToken := Just "revoked" } t)
        | Left e => putStrLn e
    accessToken c file >>= printLn
