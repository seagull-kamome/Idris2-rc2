module Network.WebAPI.AI.Providers

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- An OpenAI-compatible `Endpoint` for each service. Getting a key or an
-- OAuth client: doc/webapi-getting-started.md.

import System

import Network.WebAPI.AI.OpenAI
import Network.WebAPI.Auth.OAuth2

%default total

bearer : String -> List (String, String)
bearer t = [("Authorization", "Bearer " ++ t)]

fixed : String -> List (String, String) -> Endpoint
fixed url hs = MkEndpoint url (pure (Right hs))

fromEnv : HasIO io => String -> (String -> Endpoint) -> io (Either String Endpoint)
fromEnv var mk = pure $ maybe (Left (var ++ " is not set")) (Right . mk) !(getEnv var)

export
claude : (apiKey : String) -> Endpoint
claude = fixed "https://api.anthropic.com/v1" . bearer

||| From `ANTHROPIC_API_KEY`.
export
claudeFromEnv : HasIO io => io (Either String Endpoint)
claudeFromEnv = fromEnv "ANTHROPIC_API_KEY" claude

export
gemini : (apiKey : String) -> Endpoint
gemini = fixed "https://generativelanguage.googleapis.com/v1beta/openai" . bearer

||| From `GEMINI_API_KEY`.
export
geminiFromEnv : HasIO io => io (Either String Endpoint)
geminiFromEnv = fromEnv "GEMINI_API_KEY" gemini

||| The scopes Google's Gemini OAuth guide asks for.
export
geminiScopes : List String
geminiScopes = [ "https://www.googleapis.com/auth/cloud-platform"
               , "https://www.googleapis.com/auth/generative-language.retriever" ]

||| Gemini with the OAuth token `login` saved at `tokenFile`, refreshed
||| as needed. `project` is the Google Cloud project billed for the
||| calls (sent as `x-goog-user-project`).
export partial
geminiOAuth : Client -> (tokenFile : String) -> (project : String) -> Endpoint
geminiOAuth c path project = MkEndpoint
    "https://generativelanguage.googleapis.com/v1beta/openai"
    (map (map (\t => ("x-goog-user-project", project) :: bearer t)) (accessToken c path))

||| llama.cpp's `llama-server` (or any OpenAI-compatible server) at
||| `baseUrl`, e.g. `http://localhost:8080/v1`. The key is needed only
||| when the server was started with `--api-key`.
export
llama : (baseUrl : String) -> (apiKey : Maybe String) -> Endpoint
llama url key = fixed url (maybe [] bearer key)
