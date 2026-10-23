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
import Data.List1
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
  ||| The most the status line and the headers of an answer may take: more is 502.
  maxHeadBytes : Int
  ||| Whether the server is asked for the path below the prefix (`/api/users` for
  ||| `/users` with the prefix `/api`) or for the path of the request as it is.
  stripMount : Bool
  ||| The `Host` header of the forwarded request; the address and port of the server
  ||| when `Nothing`.
  hostHeader : Maybe String

||| 30 seconds, 16 MiB, 64 KiB of head, the prefix stripped, `Host` the server's own.
public export
defaultProxy : ProxyOptions
defaultProxy = MkProxyOptions 30000 16777216 65536 True Nothing

-- The headers that are about one connection and not passed on, in lower case
-- (RFC 9110, 7.6.1), besides the ones that `proxy` replaces itself.
hopByHop : List String
hopByHop = [ "connection", "keep-alive", "proxy-authenticate", "proxy-authorization"
           , "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade" ]

-- The headers that say where a request came from or by what: a client could write
-- them to be taken for someone else by a server that trusts them. They are not passed
-- on (the proxy does not know the address of the client, so it does not write
-- `X-Forwarded-For` itself); `X-Forwarded-Host` and `X-Forwarded-Proto` are set.
forwardedBy : List String
forwardedBy = [ "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"
              , "x-forwarded-port", "x-real-ip" ]

-- `a.b.c.d`; nothing for an address `connect` cannot use anyway.
render : SocketAddress -> String
render (IPv4Addr a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
render _ = ""

-- Why an exchange did not give an answer.
data Failed = TimedOut | Bad String

-- The tokens (lower case) of the `Connection` headers: the names of the other
-- headers that are about this connection only (RFC 9110, 7.6.1).
connectionTokens : List (String, String) -> List String
connectionTokens hdrs =
  [ toLower (trim t) | (k, v) <- hdrs, toLower k == "connection", t <- forget (split (== ',') v) ]

-- The headers that go on to the other side.
passedOn : (besides : List String) -> List (String, String) -> List (String, String)
passedOn besides hdrs =
  let dropped = besides ++ hopByHop ++ connectionTokens hdrs
  in filter (\(k, _) => not (elem (toLower k) dropped)) hdrs

||| Forward the requests whose path is at or below `mountAt` to the HTTP server at
||| `upstream` (an IPv4 address: a host name would need a blocking lookup) and
||| `port`, and give every other request to `next`. The request goes out as
||| HTTP/1.0 with `Connection: close`, so the server answers without chunks and
||| the answer ends with its connection; the answer is given back with its status
||| and headers, except the ones about the connection (also the ones `Connection`
||| names) and `Content-Length`, which the server sets again. `HEAD` is asked as
||| `GET` so that `Content-Length` is right. The request has `Host`, `Connection`,
||| `X-Forwarded-Host` (the original `Host`) and `X-Forwarded-Proto: http`; the
||| headers that say where a request came from (`Forwarded`, `X-Forwarded-For`,
||| `X-Real-IP`, ...) the client wrote are not passed on.
|||
||| The request is sent while the answer is read: a server that answers without reading
||| all of the body (413, 401) and closes still gives its answer, and one that fills the
||| connection with its answer does not stall the sending.
|||
||| A request is answered with 400, and not forwarded, if its target does not start
||| with `/` (an absolute URI), has a `.` or `..` segment (also percent-encoded, with
||| `/` or `\` ending a segment), or if a method, target or header name has a control
||| character in it, or a header value has one other than HTAB. An answer is 502 when
||| the server cannot be reached or does not answer with a proper head (`HTTP/`, a
||| status of three digits from 200 to 599, `Content-Length` that is plain digits, no
||| `Transfer-Encoding`, a head of at most `maxHeadBytes`) and a body that is complete
||| (the length it says, or else the end of the connection), or gives more than
||| `maxResponseBytes`, and 504 after `timeoutMs`. No `Upgrade` (WebSocket), no
||| `100-continue`, no streaming: the answer is held whole.
export
proxy : {default defaultProxy options : ProxyOptions}
     -> (mountAt : String) -> (upstream : SocketAddress) -> (port : Port) -> (next : Handler) -> Handler
proxy {options} mountAt upstream port next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just below =>
    if not acceptable then liftIO (text 400 "bad request\n")
    else if not (fieldSafe hostValue) then liftIO (text 500 "bad proxy configuration\n")
    else do
      deadline <- case options.timeoutMs of
                    Z => pure Nothing
                    ms => (\t => Just (t + ms)) <$> now
      result <- talk deadline (upstreamPath below)
      case result of
        Left TimedOut => liftIO (text 504 "gateway timeout\n")
        Left (Bad message) => liftIO (text 502 ("bad gateway: " ++ message ++ "\n"))
        Right resp => pure resp
  where
    -- A request that can be forwarded as it is.
    acceptable : Bool
    acceptable =
      isPrefixOf "/" req.path
      && all noControl (req.method :: req.path :: map fst req.headers)
      && all (fieldSafe . snd) req.headers
      && not (hasDotSegment req.path)

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
          passed = passedOn ("host" :: "content-length" :: "expect" :: forwardedBy) req.headers
          forwardedHost = maybe [] (\h => [("X-Forwarded-Host", h)]) (lookup "host" req.headers)
          framing = if size > 0 || elem method ["POST", "PUT", "PATCH"] then [("Content-Length", show size)] else []
          fields = the (List (String, String)) [("Host", hostValue), ("Connection", "close")]
                   ++ passed ++ forwardedHost ++ [("X-Forwarded-Proto", "http")] ++ framing
      in method ++ " " ++ path ++ " HTTP/1.0\r\n" ++ concatMap (\(k, v) => k ++ ": " ++ v ++ "\r\n") fields ++ "\r\n"

    -- `Nothing` when `deadline` has passed.
    receive : Maybe Time -> Sock -> Buffer -> (off, len : Int) -> Task (Maybe (Either Errno Int))
    receive Nothing conn buf off len = Just <$> recv conn buf off len
    receive (Just t) conn buf off len = recvUntil t conn buf off len

    transmit : Maybe Time -> Sock -> Buffer -> Task (Maybe (Either Errno ()))
    transmit Nothing conn buf = Just <$> sendAll conn buf 0 (byteLength buf)
    transmit (Just t) conn buf = sendAllUntil t conn buf 0 (byteLength buf)

    -- Send the request, and then wait for ever: it is given up when the answer is
    -- in. An error or a time out here is not the end of the exchange, the server may
    -- have answered and closed.
    send : Maybe Time -> Sock -> Buffer -> Task ()
    send deadline conn head = do
      sent <- transmit deadline conn head
      case sent of
        Just (Right ()) => ignore (transmit deadline conn req.body) *> Empty
        _ => Empty

    -- What the server sends until it closes (at most `maxResponseBytes`), and whether
    -- it did close: a read that failed leaves what was received.
    collect : Maybe Time -> Sock -> Task (Either Failed (Buffer, Int, Bool))
    collect deadline conn = do
      buf <- liftIO (newBuf 4096)
      go buf 0
      where
        -- One byte more than may be taken is read: the end of an answer of exactly
        -- the limit is not mistaken for more of it.
        go : Buffer -> (len : Int) -> Task (Either Failed (Buffer, Int, Bool))
        go buf len = do
          Just buf' <- liftIO (growBuffer buf (len + 1) (options.maxResponseBytes + 1))
            | Nothing => pure (Left (Bad "answer too large"))
          r <- receive deadline conn buf' len (min 65536 (byteLength buf' - len))
          case r of
            Nothing => pure (Left TimedOut)
            Just (Right 0) => pure (Right (buf', len, True))
            Just (Right n) =>
              if len + n > options.maxResponseBytes then pure (Left (Bad "answer too large")) else do
                -- the head has to end within its limit, before more is read
                headEnded <- if len <= options.maxHeadBytes && len + n > options.maxHeadBytes
                               then isJust <$> liftIO (findHeadEnd buf' (options.maxHeadBytes))
                               else pure True
                if headEnded then go buf' (len + n) else pure (Left (Bad "head of the answer too large"))
            Just (Left _) => pure (Right (buf', len, False))

    -- The head is parsed as a request head is: `HTTP/1.1 200 OK` is a version, a
    -- status and the rest.
    toResponse : Buffer -> (len : Int) -> (closed : Bool) -> Task (Either Failed Response)
    toResponse buf len closed = do
      Just headEnd <- liftIO (findHeadEnd buf len)
        | Nothing => pure (Left (Bad "no head in the answer"))
      Just (version, code, _, hdrs) <- liftIO (parseRequestHead buf headEnd)
        | Nothing => pure (Left (Bad "bad head in the answer"))
      let status = if length code == 3 && all isDigit (unpack code) then parsePositive {a = Int} code else Nothing
      case (isPrefixOf "HTTP/" version, status, bodyLength hdrs) of
        (True, Just st, Just _) =>
          if st < 200 || st > 599 || headEnd + 4 > options.maxHeadBytes
             || not (all (noControl . fst) hdrs && all (fieldSafe . snd) hdrs)
            then pure (Left (Bad "bad status or head in the answer"))
            else do
              let start = headEnd + 4
              let avail = len - start
              let declared = lookup "content-length" hdrs >>= parsePositive {a = Int}
              -- complete: the length it says is there, or the connection was closed
              -- (also for a status that has no body)
              if hasBody st && not (maybe closed (<= avail) declared)
                then pure (Left (Bad "the answer is shorter than it says, or was cut off"))
                else do
                  body <- liftIO (slice buf start (if hasBody st then maybe avail (min avail) declared else 0))
                  pure (Right (MkResponse st (passedOn ["content-length"] hdrs) body))
        _ => pure (Left (Bad "bad head or framing in the answer"))

    talk : Maybe Time -> (path : String) -> Task (Either Failed Response)
    talk deadline path = do
      connected <- the (Task (Maybe (Either Errno Sock))) $ case deadline of
                     Nothing => Just <$> connect upstream port
                     Just t => timeoutAt t (connect upstream port)
      case connected of
        Nothing => pure (Left TimedOut)
        Just (Left _) => pure (Left (Bad "cannot connect"))
        Just (Right conn) => withSock conn $ do
          head <- liftIO (fromString (requestHead path))
          -- the answer is read while the request is sent; `send` never ends
          received <- race (collect deadline conn) (send deadline conn head)
          case received of
            Left (Left failed) => pure (Left failed)
            Left (Right (buf, len, closed)) => toResponse buf len closed
            Right () => pure (Left (Bad "unreachable"))
