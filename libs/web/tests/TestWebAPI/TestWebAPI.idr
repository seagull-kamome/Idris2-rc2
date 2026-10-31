module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Client.WebAPI end to end, without outbound network: a mock
-- OpenAI-compatible API and OAuth 2.0 token endpoint (Network.HTTP.Server
-- in a forked thread) is driven by `chat` and `login`.
--   * chat: a reply, a rejected key, no key, an unreachable server;
--   * login with PKCE and the loopback redirect: the "browser" is another
--     forked thread started from `Client.onAuthUrl`; the mock checks the
--     code verifier against the challenge it saw on /auth. Then the token
--     file: saved, used as is while valid, refreshed once expired, and a
--     revoked refresh token;
--   * login refused by the user (error=access_denied on the redirect).
-- The paste-the-address path reads stdin and is not covered here.
-- `login` polls stdin, so the runner must give it an open, silent stdin
-- (verify.sh passes a FIFO).

import Network.Address
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Language.JSON
import System.Directory
import System.File

import Network.HTTP.Client.Curl
import Network.HTTP.Client.WebAPI.Auth.PKCE
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.Providers
import Network.HTTP.Client.WebAPI.Auth.OAuth2
import Network.HTTP.Server
import Network.URL

import System.Concurrency
import System.Concurrency.RC2

mockPort : Port
mockPort = 18726

napMs : Int -> IO ()
napMs ms = do
    m <- makeMutex
    c <- makeCondition
    mutexAcquire m
    conditionWaitTimeout c m (ms * 1000)
    mutexRelease m

bodyString : Request -> IO String
bodyString req = getString req.body 0 (byteLength req.body)

oauthError : Int -> String -> String -> IO Response
oauthError status code desc =
    Response.json status (JObject [("error", JString code), ("error_description", JString desc)])

-- The mock. `challenge` remembers the code_challenge seen on /auth for "good-code".
mock : IORef (Maybe String) -> Handler
mock challenge req respond =
    case (req.method, fst (break (== '?') req.path)) of
      ("GET", "/auth") => do
          for_ (lookup "code_challenge" (parseQuery (snd (break (== '?') req.path)))) $ \c =>
              writeIORef challenge (Just c)
          respond !(Response.json 200 (JObject []))
      ("POST", "/v1/chat/completions") => do
          case lookup "authorization" req.headers of
            Just "Bearer test-key" => do
                body <- bodyString req
                let (model, text, maxTokens) = describe (parse body)
                respond !(Response.json 200 (JObject
                    [ ("model", JString model)
                    , ("choices", JArray [JObject
                        [ ("index", JNumber 0)
                        , ("message", JObject [("role", JString "assistant"), ("content", JString text)])
                        , ("finish_reason", JString "stop") ]]) ]))
            _ => respond !(Response.json 401 (JObject
                    [("error", JObject [("message", JString "invalid api key"), ("type", JString "auth")])]))
      ("POST", "/token") => do
          form <- parseQuery <$> bodyString req
          if lookup "client_id" form /= Just "cid" || lookup "client_secret" form /= Just "sec"
            then respond !(oauthError 401 "invalid_client" "bad client")
            else case lookup "grant_type" form of
              Just "authorization_code" => do
                  seen <- readIORef challenge
                  let verifier = fromMaybe "" (lookup "code_verifier" form)
                  if lookup "code" form == Just "good-code" && seen == Just (challengeS256 verifier)
                    then respond !(Response.json 200 (JObject
                           [ ("access_token", JString "at-1"), ("refresh_token", JString "rt-1")
                           , ("expires_in", JNumber 3600) ]))
                    else respond !(oauthError 400 "invalid_grant" "bad code or verifier")
              Just "refresh_token" =>
                  if lookup "refresh_token" form == Just "rt-1"
                    then respond !(Response.json 200 (JObject
                           [("access_token", JString "at-2"), ("expires_in", JNumber 3600)]))
                    else respond !(oauthError 400 "invalid_grant" "bad refresh token")
              _ => respond !(oauthError 400 "unsupported_grant_type" "unsupported")
      ("POST", "/stop") => do
          stop
          respond !(Response.json 200 (JObject []))
      _ => respond !(Response.notFound "nope")
  where
    -- "echo: <last message> (model <m>, max_tokens <n>)" from the request JSON
    describe : Maybe JSON -> (String, String, String)
    describe (Just (JObject kvs)) =
        let model = case lookup "model" kvs of { Just (JString m) => m; _ => "?" }
            lastMsg = case lookup "messages" kvs of
                        Just (JArray ms) => case last' ms of
                                              Just (JObject m) => case lookup "content" m of
                                                                    Just (JString c) => c
                                                                    _ => "?"
                                              _ => "?"
                        _ => "?"
            mt = case lookup "max_tokens" kvs of { Just (JNumber n) => show (cast {to = Integer} n); _ => "none" }
        in (model, "echo: " ++ lastMsg ++ " (model " ++ model ++ ", max_tokens " ++ mt ++ ")", mt)
    describe _ = ("?", "bad request body", "?")

-- Wait until the server thread accepts connections.
partial
waitServer : String -> Nat -> IO ()
waitServer base Z = putStrLn "server did not start"
waitServer base (S k) = do
    Right _ <- fetch curlClient (get (base ++ "/ping"))
        | Left _ => napMs 20 >> waitServer base k
    pure ()

-- The "browser": opens the authorization URL (the mock remembers the
-- challenge), then follows the redirect with `extra` appended.
partial
browser : (extra : String -> String) -> String -> String -> IO ()
browser extra authUrl redirect = do
    _ <- fetch curlClient (get authUrl)
    let state = fromMaybe "" (lookup "state" (parseQuery (snd (break (== '?') authUrl))))
    _ <- fetch curlClient (get (redirect ++ "/?state=" ++ state ++ extra state))
    pure ()

-- `login` blocks waiting for the redirect, so the browser runs in its own thread.
partial
browserThread : (String -> String) -> String -> String -> IO ()
browserThread extra authUrl redirect = ignore $ forkJoin {a = ()} (browser extra authUrl redirect)

partial
main : IO ()
main = do
    let base = "http://127.0.0.1:" ++ show mockPort
    challenge <- newIORef Nothing
    srv <- forkJoin {a = ()} $ serve {bindAddr = IPv4Addr 127 0 0 1} mockPort (mock challenge)
    waitServer base 100

    putStrLn "--- chat ---"
    let req = { maxTokens := Just 64 } (chatRequest "llama-3" [MkMessage User "ping"])
    Right r <- chat curlClient (llama (base ++ "/v1") (Just "test-key")) req
        | Left e => printLn e
    printLn (reply r)
    chat curlClient (llama (base ++ "/v1") (Just "wrong")) req >>= printLn . map reply
    chat curlClient (llama (base ++ "/v1") Nothing) req >>= printLn . map reply
    chat curlClient (llama "http://127.0.0.1:1/v1" Nothing) req >>= \case
        Left (TransportError _) => putStrLn "TransportError"
        other => printLn (map reply other)

    putStrLn "--- login (browser redirect) ---"
    let c = MkClient (base ++ "/auth") (base ++ "/token") "cid" (Just "sec") ["s1", "s2"] []
                     (Just (browserThread (\_ => "&code=good-code")))
    let file = "oauth-token.json"
    Right t <- login curlClient c
        | Left e => putStrLn ("login: " ++ e)
    printLn (t.accessToken, t.refreshToken)
    Right () <- saveToken file t
        | Left e => putStrLn e
    accessToken curlClient c file >>= printLn
    Right () <- saveToken file ({ expiresAt := 0 } t)
        | Left e => putStrLn e
    accessToken curlClient c file >>= printLn
    map (\t' => (t'.accessToken, t'.refreshToken)) <$> loadToken file >>= printLn
    Right () <- saveToken file ({ expiresAt := 0, refreshToken := Just "revoked" } t)
        | Left e => putStrLn e
    accessToken curlClient c file >>= printLn
    _ <- removeFile file

    putStrLn "--- login (refused) ---"
    let c2 = { onAuthUrl := Just (browserThread (\_ => "&error=access_denied")) } c
    login curlClient c2 >>= \case
        Left e => putStrLn ("login: " ++ e)
        Right t' => putStrLn ("unexpected token " ++ t'.accessToken)

    putStrLn "--- login (wrong code) ---"
    let c3 = { onAuthUrl := Just (browserThread (\_ => "&code=bad-code")) } c
    login curlClient c3 >>= \case
        Left e => putStrLn ("login: " ++ e)
        Right t' => putStrLn ("unexpected token " ++ t'.accessToken)

    _ <- fetch curlClient (post (base ++ "/stop") "")
    join srv
