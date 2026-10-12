module Network.WebAPI.AI.OpenAI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Client for OpenAI's chat completions API, which Claude, Gemini and
-- llama.cpp's llama-server also serve. Network.WebAPI.AI.Providers
-- has an `Endpoint` for each.

import Data.List
import Data.Maybe

import Network.Curl.Fetch
import Network.WebAPI.JSON

%default total

public export
data Role = System | User | Assistant

export
Show Role where
  show System    = "system"
  show User      = "user"
  show Assistant = "assistant"

public export
record Message where
  constructor MkMessage
  role    : Role
  content : String

public export
record ChatRequest where
  constructor MkChatRequest
  model       : String
  messages    : List Message
  maxTokens   : Maybe Nat
  temperature : Maybe Double

||| Adjust the optional fields by record update, e.g.
||| `{ maxTokens := Just 1024 } (chatRequest model msgs)`.
export
chatRequest : (model : String) -> List Message -> ChatRequest
chatRequest m ms = MkChatRequest m ms Nothing Nothing

public export
record Choice where
  constructor MkChoice
  message      : Message
  finishReason : Maybe String

public export
record ChatResponse where
  constructor MkChatResponse
  model   : String
  choices : List Choice

||| The first choice's text, which is all there is unless `n` > 1.
export
reply : ChatResponse -> Maybe String
reply r = map (content . message) (head' r.choices)

||| `authHeaders` runs before every request, so a token that expires
||| can refresh itself there.
public export
record Endpoint where
  constructor MkEndpoint
  baseUrl     : String
  authHeaders : IO (Either String (List (String, String)))

public export
data ApiError
  = AuthError String
  | TransportError String
  | HttpStatus Int String
  | DecodeError String

export
Show ApiError where
  show (AuthError e)      = "AuthError " ++ e
  show (TransportError e) = "TransportError " ++ e
  show (HttpStatus s e)   = "HttpStatus " ++ show s ++ " " ++ e
  show (DecodeError e)    = "DecodeError " ++ e

export
encodeChatRequest : ChatRequest -> JSON
encodeChatRequest r = JObject $
    [ ("model", JString r.model)
    , ("messages", JArray (map msg r.messages)) ]
    ++ catMaybes [ map (\n => ("max_tokens", JNumber (cast n))) r.maxTokens
                 , map (\t => ("temperature", JNumber t)) r.temperature ]
  where
    msg : Message -> JSON
    msg m = JObject [("role", JString (show m.role)), ("content", JString m.content)]

export
decodeChatResponse : JSON -> Either String ChatResponse
decodeChatResponse j = maybe (Left ("unexpected response: " ++ render j)) Right $ do
    cs <- at ["choices"] j >>= arr
    MkChatResponse (fromMaybe "" (at ["model"] j >>= str)) <$> traverse choice cs
  where
    role : String -> Role
    role "system" = System
    role "user"   = User
    role _        = Assistant

    choice : JSON -> Maybe Choice
    choice c = do
        m <- at ["message"] c
        -- A tool-call-only message has `"content": null`.
        let text = fromMaybe "" (at ["content"] m >>= str)
        pure $ MkChoice (MkMessage (role (fromMaybe "assistant" (at ["role"] m >>= str))) text)
                        (at ["finish_reason"] c >>= str)

||| OpenAI and Claude send `{"error": {"message": ...}}`; Gemini wraps
||| it in a one-element array.
export
errorMessage : String -> String
errorMessage body = fromMaybe body $ do
    j <- parse body
    let j' = fromMaybe j (arr j >>= head')
    at ["error", "message"] j' >>= str

export partial
chat : HasIO io => Endpoint -> ChatRequest -> io (Either ApiError ChatResponse)
chat ep req = liftIO $ do
    Right auth <- ep.authHeaders
        | Left e => pure (Left (AuthError e))
    Right resp <- fetch (post (ep.baseUrl ++ "/chat/completions")
                              {headers = ("Content-Type", "application/json") :: auth}
                              (render (encodeChatRequest req)))
        | Left e => pure (Left (TransportError (show e)))
    pure $ if resp.status < 200 || resp.status >= 300
        then Left (HttpStatus resp.status (errorMessage resp.body))
        else case parse resp.body of
            Nothing => Left (DecodeError ("not JSON: " ++ resp.body))
            Just j  => mapFst DecodeError (decodeChatResponse j)
