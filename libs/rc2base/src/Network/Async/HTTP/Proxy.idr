||| A reverse proxy for `Network.Async.HTTP.Router`: `proxy` is a `Handler`
||| transformer that forwards the requests under a URL prefix to an HTTP server and
||| gives its answer back. The connection to the server is a task on the scheduler,
||| so a slow server holds up only the connection of its request. See
||| `doc/async-http-router.md`.
module Network.Async.HTTP.Proxy

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Buffer
import Data.List
import Data.Maybe
import Data.String
import Network.Async
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.Socket.Data
import System.Posix.Errno

%default covering

||| What `proxy` may be asked to tune.
public export
record ProxyOptions where
  constructor MkProxyOptions
  ||| How long the exchange with the server may take, in milliseconds, from the
  ||| connect to the last byte of its answer: after that the answer is 504. 0 is no
  ||| limit.
  timeoutMs : Nat
  ||| The most of an answer that is taken: more is answered with 502.
  maxResponseBytes : Int
  ||| Whether the server is asked for the path below the prefix (`/api/users` for
  ||| `/users` with the prefix `/api`) or for the path of the request as it is.
  stripMount : Bool
  ||| The `Host` header of the forwarded request; the address and port of the server
  ||| when `Nothing`.
  hostHeader : Maybe String

||| 30 seconds, 16 MiB, the prefix stripped, `Host` the server's own.
public export
defaultProxy : ProxyOptions
defaultProxy = MkProxyOptions 30000 16777216 True Nothing

-- The headers that are about one connection and not passed on, in lower case
-- (RFC 9110, 7.6.1), besides the ones that `proxy` replaces itself.
hopByHop : List String
hopByHop = [ "connection", "keep-alive", "proxy-authenticate", "proxy-authorization"
           , "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade" ]

-- `a.b.c.d`; nothing for an address `connect` cannot use anyway.
render : SocketAddress -> String
render (IPv4Addr a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
render _ = ""

||| Forward the requests whose path is at or below `mountAt` to the HTTP server at
||| `upstream` (an IPv4 address: a host name would need a blocking lookup) and
||| `port`, and give every other request to `next`. The request goes out as
||| HTTP/1.0 with `Connection` closing, so the server answers without chunks and
||| the answer ends with its connection; the answer is given back with its status
||| and headers, except the ones about the connection and `Content-Length`, which
||| the server sets again. `HEAD` is asked as `GET` so that `Content-Length` is
||| right. The request has `Host` and `X-Forwarded-Host` (the original `Host`).
||| An answer is 502 when the server cannot be reached or does not answer with a
||| proper head and a body of the length it says, or gives more than
||| `maxResponseBytes`, and 504 after `timeoutMs`. No `Upgrade` (WebSocket), no
||| `100-continue`, no streaming: the answer is held whole.
export
proxy : {default defaultProxy options : ProxyOptions}
     -> (mountAt : String) -> (upstream : SocketAddress) -> (port : Port) -> (next : Handler) -> Handler
proxy {options} mountAt upstream port next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just below => do
    result <- case options.timeoutMs of
                Z => Just <$> talk (upstreamPath below)
                ms => do
                  t <- now
                  timeoutAt (t + ms) (talk (upstreamPath below))
    case result of
      Nothing => liftIO (text 504 "gateway timeout\n")
      Just (Left message) => liftIO (text 502 ("bad gateway: " ++ message ++ "\n"))
      Just (Right resp) => pure resp
  where
    hostValue : String
    hostValue = fromMaybe (render upstream ++ ":" ++ show port) options.hostHeader

    -- The target of the forwarded request: the segments as they stand in the request.
    upstreamPath : (below : List String) -> String
    upstreamPath below =
      if not options.stripMount then req.path else
        let (target, query) = break (== '?') req.path
            slash = if isSuffixOf "/" target && not (null below) then "/" else ""
        in "/" ++ joinBy "/" below ++ slash ++ query

    requestHead : (path : String) -> String
    requestHead path =
      let method = if req.method == "HEAD" then "GET" else req.method
          size = byteLength req.body
          replaced = "host" :: "content-length" :: "x-forwarded-host" :: "expect" :: hopByHop
          passed = filter (\(k, _) => not (elem k replaced)) req.headers
          forwardedHost = maybe [] (\h => [("X-Forwarded-Host", h)]) (lookup "host" req.headers)
          framing = if size > 0 || elem method ["POST", "PUT", "PATCH"] then [("Content-Length", show size)] else []
          fields = the (List (String, String)) [("Host", hostValue)] ++ passed ++ forwardedHost ++ framing
      in method ++ " " ++ path ++ " HTTP/1.0\r\n" ++ concatMap (\(k, v) => k ++ ": " ++ v ++ "\r\n") fields ++ "\r\n"

    -- Everything the server sends until it closes; `Left` says why not.
    collect : Sock -> Task (Either String (Buffer, Int))
    collect conn = do
      buf <- liftIO (newBuf 4096)
      go buf 0
      where
        go : Buffer -> (len : Int) -> Task (Either String (Buffer, Int))
        go buf len = do
          Just buf' <- liftIO (growBuffer buf (len + 1) options.maxResponseBytes)
            | Nothing => pure (Left "answer too large")
          r <- recv conn buf' len (min 65536 (byteLength buf' - len))
          case r of
            Right 0 => pure (Right (buf', len))
            Right n => go buf' (len + n)
            Left _ => pure (Left "cannot read the answer")

    -- The head is parsed as a request head is: `HTTP/1.1 200 OK` is a version, a
    -- status and the rest.
    toResponse : Buffer -> (len : Int) -> Task (Either String Response)
    toResponse buf len = do
      Just headEnd <- liftIO (findHeadEnd buf len)
        | Nothing => pure (Left "no head in the answer")
      Just (_, code, hdrs) <- liftIO (parseHead buf headEnd)
        | Nothing => pure (Left "bad head in the answer")
      case parsePositive {a = Int} code of
        Nothing => pure (Left "bad status in the answer")
        Just status => do
          let start = headEnd + 4
          let avail = len - start
          let declared = lookup "content-length" hdrs >>= parsePositive {a = Int}
          if hasBody status && maybe False (> avail) declared
            then pure (Left "the answer is shorter than it says")
            else do
              body <- liftIO (slice buf start (maybe avail (min avail) declared))
              let kept = filter (\(k, _) => not (elem k ("content-length" :: hopByHop))) hdrs
              pure (Right (MkResponse status kept body))

    talk : (path : String) -> Task (Either String Response)
    talk path = do
      Right conn <- connect upstream port
        | Left _ => pure (Left "cannot connect")
      withSock conn $ do
        head <- liftIO (fromString (requestHead path))
        Right () <- sendAll conn head 0 (byteLength head)
          | Left _ => pure (Left "cannot send the request")
        Right () <- sendAll conn req.body 0 (byteLength req.body)
          | Left _ => pure (Left "cannot send the request")
        Right (buf, len) <- collect conn
          | Left message => pure (Left message)
        toResponse buf len
