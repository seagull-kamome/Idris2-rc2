module Network.HTTP.Client

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A JS `fetch()`-shaped HTTP client interface: one synchronous request per
-- call, plain records in and out. `Network.HTTP.Client.Curl` is the
-- implementation on libcurl; importing it gives a `CurlClient`
-- (rc2base/doc/http-client.md).

import Data.Buffer

------------------------------------------------------------------------
-- Request/response types
------------------------------------------------------------------------

||| `OTHER` covers any verb without a dedicated constructor.
public export
data Method = GET | POST | PUT | PATCH | DELETE | HEAD | OTHER String

public export methodName : Method -> String
methodName GET       = "GET"
methodName POST      = "POST"
methodName PUT       = "PUT"
methodName PATCH     = "PATCH"
methodName DELETE    = "DELETE"
methodName HEAD      = "HEAD"
methodName (OTHER m) = m

||| Build with `get`/`post`/`request`, then adjust fields with record
||| update, e.g. `{ headers := [("Accept", "application/json")] } (get url)`.
public export
record FetchRequest where
  constructor MkFetchRequest
  url     : String
  method  : Method
  headers : List (String, String)
  body    : Maybe String

||| `headers` in the order the server sent them.
public export
record FetchResponse where
  constructor MkFetchResponse
  status  : Int
  headers : List (String, String)
  body    : String

||| Same as `FetchResponse`, with the body as raw bytes.
public export
record FetchResponseBytes where
  constructor MkFetchResponseBytes
  status  : Int
  headers : List (String, String)
  body    : Buffer

||| `TransportError`: the transfer itself failed (the message is the
||| implementation's own). An HTTP 4xx/5xx is not an error here (as with JS
||| `fetch()`), except in `fetchText`.
||| `SetupError`: something before the transfer failed.
public export
data FetchError = SetupError String | TransportError String | HttpError Int

export
Show FetchError where
  show (SetupError msg)     = "SetupError " ++ msg
  show (TransportError msg) = "TransportError " ++ msg
  show (HttpError s)        = "HttpError " ++ show s

------------------------------------------------------------------------
-- Request builders
------------------------------------------------------------------------

export
request : Method -> String -> {default [] headers : List (String, String)} -> {default Nothing body : Maybe String} -> FetchRequest
request method url = MkFetchRequest url method headers body

export
get : String -> {default [] headers : List (String, String)} -> FetchRequest
get url = request GET url {headers}

||| `body` is sent as-is; set `Content-Type` yourself if needed.
export
post : (url : String) -> {default [] headers : List (String, String)} -> (body : String) -> FetchRequest
post url body = request POST url {headers} {body=Just body}

------------------------------------------------------------------------
-- The interface
------------------------------------------------------------------------

||| An HTTP client. `h` is the client value (a configured implementation, or
||| a stub in a test).
public export
interface HTTPClient h where
  ||| Performs `req`, capturing the body as a `String` (cut at its first
  ||| NUL; use `fetchBytes` for binary bodies).
  fetch : HasIO io => h -> FetchRequest -> io (Either FetchError FetchResponse)
  ||| Same as `fetch`, with the body as raw bytes.
  fetchBytes : HasIO io => h -> FetchRequest -> io (Either FetchError FetchResponseBytes)

||| `GET url`, returning just the body; a non-2xx status becomes
||| `HttpError`.
export
fetchText : (HTTPClient h, HasIO io) => h -> String -> io (Either FetchError String)
fetchText http url = do
    Right resp <- fetch http (get url)
        | Left err => pure (Left err)
    pure $ if resp.status >= 200 && resp.status < 300
              then Right resp.body
              else Left (HttpError resp.status)
