module Network.HTTP.Client.Curl

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The libcurl implementation of Network.HTTP.Client's `HTTPClient`, over
-- Network.HTTP.Client.Curl.Raw: one synchronous transfer per call, with
-- curl_global_init/easy handle/slist bookkeeping hidden. Importing this
-- module brings Network.HTTP.Client with it.

import Data.Buffer
import Data.Maybe
import Data.String

import public Network.HTTP.Client
import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

%default covering

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------

||| What `curlClientWith` may be asked to tune.
public export
record CurlOptions where
  constructor MkCurlOptions
  ||| How long making the connection may take, in milliseconds (0: libcurl's own default).
  connectTimeoutMs : Nat
  ||| How long the whole transfer may take, in milliseconds (0: no limit).
  totalTimeoutMs : Nat
  ||| The transfer is aborted if it is slower than this many bytes per second
  ||| for `lowSpeedSeconds` seconds: it stops a transfer that hangs, without
  ||| limiting one that makes progress.
  lowSpeedBytesPerSec : Nat
  ||| See `lowSpeedBytesPerSec` (0: off).
  lowSpeedSeconds : Nat
  ||| The most redirects followed (-1: no limit).
  maxRedirects : Int

||| 30 seconds to connect, no limit on the whole transfer, abort a transfer
||| that gets under 1 byte per second for 60 seconds, at most 10 redirects.
public export
defaultCurlOptions : CurlOptions
defaultCurlOptions = MkCurlOptions 30000 0 1 60 10

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

-- What goes into the request line and the headers is written to the wire as it
-- is: libcurl does not look at a CR or LF in a custom header or request
-- method, so one in a value would end the header and begin another (header
-- injection, request splitting). Network.Async.HTTP.Proxy refuses the same.
isToken : String -> Bool
isToken t = t /= "" && all (\c => isAlphaNum c || elem c (unpack "!#$%&'*+-.^_`|~")) (unpack t)

noControl : String -> Bool
noControl v = all (\c => (ord c >= 32 && ord c /= 127) || c == '\t') (unpack v)

||| Why the request cannot be sent, if it cannot: a header name that is not a
||| token, a control character in a header value, or a request method that
||| is not a token.
requestError : FetchRequest -> Maybe String
requestError req =
    if not (isToken (methodName req.method)) then Just "request method is not a token"
    else case find (\(k, v) => not (isToken k && noControl v)) req.headers of
           Just (k, _) => Just ("header " ++ show k ++ " has a name that is not a token or a control character in its value")
           Nothing => Nothing

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
    -- Without POSTFIELDS libcurl would read the body from stdin.
    ignore $ curlEasySetoptString h curlopt_COPYPOSTFIELDS (fromMaybe "" mbody)
applyMethod h m mbody = do
    ignore $ curlEasySetoptString h curlopt_CUSTOMREQUEST (methodName m)
    traverse_ (curlEasySetoptString h curlopt_COPYPOSTFIELDS) mbody

||| Returns the header slist, which setopt does not take ownership of.
applyRequest : HasIO io => CurlOptions -> AnyPtr -> FetchRequest -> io AnyPtr
applyRequest o h req = do
    ignore $ curlEasySetoptString h curlopt_URL req.url
    ignore $ curlEasySetoptLong h curlopt_FOLLOWLOCATION 1
    ignore $ curlEasySetoptLong h curlopt_MAXREDIRS o.maxRedirects
    when (o.connectTimeoutMs > 0) $
        ignore $ curlEasySetoptLong h curlopt_CONNECTTIMEOUT_MS (cast o.connectTimeoutMs)
    when (o.totalTimeoutMs > 0) $
        ignore $ curlEasySetoptLong h curlopt_TIMEOUT_MS (cast o.totalTimeoutMs)
    when (o.lowSpeedSeconds > 0) $ do
        ignore $ curlEasySetoptLong h curlopt_LOW_SPEED_LIMIT (cast o.lowSpeedBytesPerSec)
        ignore $ curlEasySetoptLong h curlopt_LOW_SPEED_TIME (cast o.lowSpeedSeconds)
    hlist <- buildHeaderList req.headers
    ignore $ curlEasySetoptPointer h curlopt_HTTPHEADER hlist
    applyMethod h req.method req.body
    pure hlist

withEasyHandle : HasIO io => (AnyPtr -> io (Either FetchError a)) -> io (Either FetchError a)
withEasyHandle body = do
    -- Initialised once for the process, and never cleaned up here: libcurl's
    -- global init and cleanup are not safe to run while another thread is in a
    -- transfer.
    MkCURLcode 0 <- curlGlobalInitOnce
        | c => pure (Left (SetupError ("curl_global_init failed: " ++ show c)))
    Just h <- curlEasyInit
        | Nothing => pure (Left (SetupError "curl_easy_init failed"))
    result <- body h
    curlEasyCleanup h
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
       => CurlOptions -> (AnyPtr -> io (Maybe (CURLcode, b))) -> (Int -> List (String, String) -> b -> r)
       -> FetchRequest -> io (Either FetchError r)
perform o capture mk req = case requestError req of
  Just why => pure (Left (SetupError why))
  Nothing => withEasyHandle $ \h => do
    hlist <- applyRequest o h req
    captured <- capture h
    curlSlistFreeAll hlist
    case captured of
        Nothing => pure (Left (SetupError "response capture failed"))
        Just (MkCURLcode 0, body) => do
            Right status <- curlEasyGetinfoLong h curlinfo_RESPONSE_CODE
                | Left c => pure (Left (TransportError (show c ++ " (" ++ curlEasyStrerror c ++ ")")))
            hdrs <- collectHeaders h curlSlistEmpty
            pure (Right (mk status hdrs body))
        Just (c, _) => pure (Left (TransportError (show c ++ " (" ++ curlEasyStrerror c ++ ")")))

------------------------------------------------------------------------
-- The client
------------------------------------------------------------------------

||| The libcurl implementation of `HTTPClient`. It holds no handle: every
||| request makes its own easy handle (libcurl itself is initialised once).
public export
data CurlClient = MkCurlClient CurlOptions

||| The libcurl client, with `defaultCurlOptions`.
export
curlClient : CurlClient
curlClient = MkCurlClient defaultCurlOptions

||| The libcurl client with its own timeouts and redirect limit.
export
curlClientWith : CurlOptions -> CurlClient
curlClientWith = MkCurlClient

export
HTTPClient CurlClient where
  fetch (MkCurlClient o) = perform o curlEasyPerformToString MkFetchResponse
  fetchBytes (MkCurlClient o) = perform o curlEasyPerformToBuffer MkFetchResponseBytes
