module Network.HTTP.Client.Curl.Fetch

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A JS `fetch()`-shaped convenience layer over Network.HTTP.Client.Curl.Raw: one
-- synchronous transfer per call, with curl_global_init/easy handle/
-- slist bookkeeping hidden behind plain records.

import Data.Buffer

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

------------------------------------------------------------------------
-- Request/response types
------------------------------------------------------------------------

||| `OTHER` covers any verb without a dedicated constructor.
public export
data Method = GET | POST | PUT | PATCH | DELETE | HEAD | OTHER String

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

||| `CurlError`: the transfer itself failed. An HTTP 4xx/5xx is not an
||| error here (as with JS `fetch()`), except in `fetchText`.
||| `SetupError`: something before the transfer failed.
public export
data FetchError = CurlError CURLcode String | SetupError String | HttpError Int

export
Show FetchError where
  show (CurlError c msg) = "CurlError " ++ show c ++ " (" ++ msg ++ ")"
  show (SetupError msg)  = "SetupError " ++ msg
  show (HttpError s)     = "HttpError " ++ show s

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
-- Internal helpers
------------------------------------------------------------------------

methodName : Method -> String
methodName GET       = "GET"
methodName POST      = "POST"
methodName PUT       = "PUT"
methodName PATCH     = "PATCH"
methodName DELETE    = "DELETE"
methodName HEAD      = "HEAD"
methodName (OTHER m) = m

buildHeaderList : HasIO io => List (String, String) -> io AnyPtr
buildHeaderList []              = pure curlSlistEmpty
buildHeaderList ((k, v) :: kvs) = do
    list <- buildHeaderList kvs
    curlSlistAppend list (k ++ ": " ++ v)

-- Setopt results are ignored: these options only fail for a feature
-- compiled out of libcurl, which `curl_easy_perform` reports anyway.
applyMethod : HasIO io => AnyPtr -> Method -> Maybe String -> io ()
applyMethod h GET  _     = ignore $ curlEasySetoptLong h curlopt_HTTPGET 1
applyMethod h HEAD _     = ignore $ curlEasySetoptLong h curlopt_NOBODY 1
applyMethod h POST mbody = do
    ignore $ curlEasySetoptLong h curlopt_POST 1
    traverse_ (curlEasySetoptString h curlopt_COPYPOSTFIELDS) mbody
applyMethod h m mbody = do
    ignore $ curlEasySetoptString h curlopt_CUSTOMREQUEST (methodName m)
    traverse_ (curlEasySetoptString h curlopt_COPYPOSTFIELDS) mbody

||| Returns the header slist, which setopt does not take ownership of.
applyRequest : HasIO io => AnyPtr -> FetchRequest -> io AnyPtr
applyRequest h req = do
    ignore $ curlEasySetoptString h curlopt_URL req.url
    ignore $ curlEasySetoptLong h curlopt_FOLLOWLOCATION 1
    hlist <- buildHeaderList req.headers
    ignore $ curlEasySetoptPointer h curlopt_HTTPHEADER hlist
    applyMethod h req.method req.body
    pure hlist

withEasyHandle : HasIO io => (AnyPtr -> io (Either FetchError a)) -> io (Either FetchError a)
withEasyHandle body = do
    MkCURLcode 0 <- curlGlobalInit
        | c => pure (Left (SetupError ("curl_global_init failed: " ++ show c)))
    Just h <- curlEasyInit
        | Nothing => do curlGlobalCleanup
                        pure (Left (SetupError "curl_easy_init failed"))
    result <- body h
    curlEasyCleanup h
    curlGlobalCleanup
    pure result

-- Terminates because libcurl's header list for a response is finite;
-- nothing structural shows that to the totality checker.
covering
collectHeaders : HasIO io => AnyPtr -> AnyPtr -> io (List (String, String))
collectHeaders h prev = do
    Just (next, name, value) <- curlEasyNextheader h curlh_HEADER (-1) prev
        | Nothing => pure []
    ((name, value) ::) <$> collectHeaders h next

covering
perform : HasIO io
       => (AnyPtr -> io (Maybe (CURLcode, b))) -> (Int -> List (String, String) -> b -> r)
       -> FetchRequest -> io (Either FetchError r)
perform capture mk req = withEasyHandle $ \h => do
    hlist <- applyRequest h req
    captured <- capture h
    curlSlistFreeAll hlist
    case captured of
        Nothing => pure (Left (SetupError "response capture failed"))
        Just (MkCURLcode 0, body) => do
            Right status <- curlEasyGetinfoLong h curlinfo_RESPONSE_CODE
                | Left c => pure (Left (CurlError c (curlEasyStrerror c)))
            hdrs <- collectHeaders h curlSlistEmpty
            pure (Right (mk status hdrs body))
        Just (c, _) => pure (Left (CurlError c (curlEasyStrerror c)))

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

||| Performs `req`, capturing the body as a `String` (cut at its first
||| NUL; use `fetchBytes` for binary bodies).
covering export
fetch : HasIO io => FetchRequest -> io (Either FetchError FetchResponse)
fetch = perform curlEasyPerformToString MkFetchResponse

covering export
fetchBytes : HasIO io => FetchRequest -> io (Either FetchError FetchResponseBytes)
fetchBytes = perform curlEasyPerformToBuffer MkFetchResponseBytes

||| `GET url`, returning just the body; a non-2xx status becomes
||| `HttpError`.
covering export
fetchText : HasIO io => String -> io (Either FetchError String)
fetchText url = do
    Right resp <- fetch (get url)
        | Left err => pure (Left err)
    pure $ if resp.status >= 200 && resp.status < 300
              then Right resp.body
              else Left (HttpError resp.status)
