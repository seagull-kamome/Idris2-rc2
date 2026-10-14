module Network.HTTP.Client.Curl

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The libcurl implementation of Network.HTTP.Client's `HTTPClient`, over
-- Network.HTTP.Client.Curl.Raw: one synchronous transfer per call, with
-- curl_global_init/easy handle/slist bookkeeping hidden. Importing this
-- module brings Network.HTTP.Client with it.

import Data.Buffer
import Data.Maybe

import public Network.HTTP.Client
import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

%default covering

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

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
                | Left c => pure (Left (TransportError (show c ++ " (" ++ curlEasyStrerror c ++ ")")))
            hdrs <- collectHeaders h curlSlistEmpty
            pure (Right (mk status hdrs body))
        Just (c, _) => pure (Left (TransportError (show c ++ " (" ++ curlEasyStrerror c ++ ")")))

------------------------------------------------------------------------
-- The client
------------------------------------------------------------------------

||| The libcurl implementation of `HTTPClient`. It holds no state: every
||| request initialises libcurl and its own easy handle.
public export
data CurlClient = MkCurlClient

||| The libcurl client.
export
curlClient : CurlClient
curlClient = MkCurlClient

export
HTTPClient CurlClient where
  fetch _ = perform curlEasyPerformToString MkFetchResponse
  fetchBytes _ = perform curlEasyPerformToBuffer MkFetchResponseBytes
