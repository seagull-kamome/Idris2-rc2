||| A minimal, single-threaded, event-driven HTTP/1.1 server.
||| One `epoll` loop (via `System.Net.Epoll`) drives everything --
||| accepting connections, parsing requests, and flushing responses --
||| on a single thread. A `Handler` gets its response back through a
||| continuation rather than a return value, so it can answer either
||| synchronously (call it immediately) or asynchronously (stash it and
||| call it once some other event source is ready). See
||| `libs/rc2base/doc/http-server.md` for the design, wire-format
||| subset supported, and known limitations.
module Network.HTTP.Server

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.IORef
import Data.Maybe
import Data.SortedMap
import Data.String

import Network.Socket
import Network.Socket.Data

import System.Net.Epoll

-- The event loop itself never terminates by construction (`loop`,
-- `acceptLoop`) -- overrides rc2base.ipkg's package-wide `--total`.
%default covering

-------------------------------------------------------------------------------
-- Requests and responses
-------------------------------------------------------------------------------

||| A parsed HTTP/1.1 request. `path` is passed through verbatim,
||| query string and all -- no URL-decoding or splitting.
public export
record Request where
  constructor MkRequest
  method  : String
  path    : String
  headers : List (String, String)
  body    : String

||| A `Handler`'s answer, passed to its `respond` continuation.
||| `Content-Length` is computed from `body` and added automatically --
||| don't set it in `headers`.
public export
record Response where
  constructor MkResponse
  status  : Int
  headers : List (String, String)
  body    : String

||| A request handler. Call the `respond` continuation once, either
||| synchronously (before returning) or later from any other IO action
||| (e.g. a callback stashed elsewhere) -- see the module doc comment.
||| Calling it more than once, or not at all, leaves the connection in
||| an unspecified state.
public export
Handler : Type
Handler = Request -> (Response -> IO ()) -> IO ()

-------------------------------------------------------------------------------
-- Minimal HTTP/1.1 wire format: request-line + headers + Content-Length body
-------------------------------------------------------------------------------

findCRLFCRLF : String -> Maybe Nat
findCRLFCRLF hay = go 0 (unpack hay)
  where
    go : Nat -> List Char -> Maybe Nat
    go i ('\r' :: '\n' :: '\r' :: '\n' :: _) = Just i
    go i (_ :: rest) = go (S i) rest
    go i [] = Nothing

parseHeaderLine : String -> Maybe (String, String)
parseHeaderLine line =
  let (name, valuePart) = break (== ':') line
  in if null valuePart
       then Nothing
       else Just (toLower (trim name), trim (strSubstr 1 (strLength valuePart - 1) valuePart))

parseHeadPart : String -> Maybe (String, String, List (String, String))
parseHeadPart headPart =
  case lines headPart of
    [] => Nothing
    (requestLine :: headerLines) =>
      case words requestLine of
        (method :: path :: _) => Just (method, path, mapMaybe parseHeaderLine headerLines)
        _                     => Nothing

contentLength : List (String, String) -> Nat
contentLength hdrs = fromMaybe 0 (lookup "content-length" hdrs >>= parsePositive {a = Nat})

-- HTTP/1.1 defaults to keep-alive; only an explicit "Connection: close"
-- ends it. HTTP/1.0 (which defaults the other way) isn't supported --
-- see the doc's "Scope" section.
connectionClose : List (String, String) -> Bool
connectionClose hdrs = maybe False ((== "close") . toLower . trim) (lookup "connection" hdrs)

reasonPhrase : Int -> String
reasonPhrase 200 = "OK"
reasonPhrase 201 = "Created"
reasonPhrase 204 = "No Content"
reasonPhrase 301 = "Moved Permanently"
reasonPhrase 302 = "Found"
reasonPhrase 304 = "Not Modified"
reasonPhrase 400 = "Bad Request"
reasonPhrase 401 = "Unauthorized"
reasonPhrase 403 = "Forbidden"
reasonPhrase 404 = "Not Found"
reasonPhrase 405 = "Method Not Allowed"
reasonPhrase 500 = "Internal Server Error"
reasonPhrase 501 = "Not Implemented"
reasonPhrase 503 = "Service Unavailable"
reasonPhrase _   = "Unknown"

serialize : Response -> String
serialize resp =
    "HTTP/1.1 " ++ show resp.status ++ " " ++ reasonPhrase resp.status ++ "\r\n"
    ++ concatMap headerLine resp.headers
    ++ "Content-Length: " ++ show (strLength resp.body) ++ "\r\n"
    ++ "\r\n" ++ resp.body
  where
    headerLine : (String, String) -> String
    headerLine (k, v) = k ++ ": " ++ v ++ "\r\n"

-------------------------------------------------------------------------------
-- Connection state
-------------------------------------------------------------------------------

record Conn where
  constructor MkConn
  sock        : Socket
  readBuf     : IORef String
  writeBuf    : IORef String
  shouldClose : IORef Bool

record ServerState where
  constructor MkServerState
  epoll      : EPoll
  listenSock : Socket
  conns      : IORef (SortedMap Int Conn)

-------------------------------------------------------------------------------
-- The event loop
-------------------------------------------------------------------------------

closeConn : ServerState -> Conn -> IO ()
closeConn st conn = do
  ignore $ remove st.epoll conn.sock.descriptor
  close conn.sock
  modifyIORef st.conns (delete conn.sock.descriptor)

finishWrite : ServerState -> Conn -> IO ()
finishWrite st conn = do
  wantsClose <- readIORef conn.shouldClose
  if wantsClose
    then closeConn st conn
    else ignore $ modify st.epoll conn.sock.descriptor epollIn

flushWrite : ServerState -> Conn -> IO ()
flushWrite st conn = do
  buf <- readIORef conn.writeBuf
  if null buf
    then finishWrite st conn
    else case !(send conn.sock buf) of
      Right n =>
        let remaining = strSubstr (cast n) (strLength buf - cast n) buf
        in do writeIORef conn.writeBuf remaining
              if null remaining
                then finishWrite st conn
                else ignore $ modify st.epoll conn.sock.descriptor (epollIn <+> epollOut)
      Left err =>
        if err == EAGAIN
          then ignore $ modify st.epoll conn.sock.descriptor (epollIn <+> epollOut)
          else closeConn st conn

-- The `respond` continuation handed to a `Handler`. `st.conns` is
-- re-checked here (not just at dispatch time) because this can run
-- much later than the request it answers -- an async handler may
-- stash it past several other events, by which point the client
-- could already be gone.
respond : ServerState -> Conn -> Response -> IO ()
respond st conn resp = do
  conns <- readIORef st.conns
  when (isJust (lookup conn.sock.descriptor conns)) $ do
    modifyIORef conn.writeBuf (++ serialize resp)
    flushWrite st conn

-- Recurses so one `recv` that happens to land two full requests in the
-- same TCP segment (or a genuinely pipelined client) doesn't strand
-- the second one waiting for a read event that may never come.
tryDispatch : ServerState -> Handler -> Conn -> IO ()
tryDispatch st handler conn = do
  buf <- readIORef conn.readBuf
  case findCRLFCRLF buf of
    Nothing => pure ()
    Just idx =>
      let headPart  = strSubstr 0 (cast idx) buf
          afterHead = strSubstr (cast idx + 4) (strLength buf - cast idx - 4) buf
      in case parseHeadPart headPart of
           Nothing => closeConn st conn
           Just (method, path, hdrs) =>
             let need = contentLength hdrs in
             if strLength afterHead < cast need
               then pure ()
               else do
                 let body     = strSubstr 0 (cast need) afterHead
                     leftover = strSubstr (cast need) (strLength afterHead - cast need) afterHead
                 writeIORef conn.readBuf leftover
                 writeIORef conn.shouldClose (connectionClose hdrs)
                 handler (MkRequest method path hdrs body) (respond st conn)
                 tryDispatch st handler conn

handleReadable : ServerState -> Handler -> Conn -> IO ()
handleReadable st handler conn =
  case !(recv conn.sock 65536) of
    Right (chunk, _) => do
      modifyIORef conn.readBuf (++ chunk)
      tryDispatch st handler conn
    Left 0   => closeConn st conn
    Left err => if err == EAGAIN then pure () else closeConn st conn

handleClientEvent : ServerState -> Handler -> ReadyEvent -> IO ()
handleClientEvent st handler ev = do
  conns <- readIORef st.conns
  case lookup ev.fd conns of
    Nothing => pure ()
    Just conn =>
      if hasEvent epollErr ev.flags || hasEvent epollHup ev.flags
        then closeConn st conn
        else do
          when (hasEvent epollIn ev.flags) $ handleReadable st handler conn
          stillOpen <- isJust . lookup ev.fd <$> readIORef st.conns
          when (stillOpen && hasEvent epollOut ev.flags) $ flushWrite st conn

-- Level-triggered, so one epoll-reported "listener readable" can hide
-- several pending connections (a burst of clients arriving between
-- `wait` calls) -- drain with `accept` until it reports EAGAIN.
acceptLoop : ServerState -> IO ()
acceptLoop st =
  case !(accept st.listenSock) of
    Left _ => pure ()
    Right (csock, _) => do
      ignore $ setNonBlocking csock.descriptor
      conn <- [| MkConn (pure csock) (newIORef "") (newIORef "") (newIORef False) |]
      modifyIORef st.conns (insert csock.descriptor conn)
      ignore $ add st.epoll csock.descriptor epollIn
      acceptLoop st

loop : ServerState -> Handler -> IO ()
loop st handler = do
  events <- wait st.epoll (-1)
  for_ events $ \ev =>
    if ev.fd == st.listenSock.descriptor
      then acceptLoop st
      else handleClientEvent st handler ev
  loop st handler

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

||| Listens on `port` (on `bindAddr`, `localhost` unless given
||| explicitly -- pass e.g. `{bindAddr = IPv4Addr 0 0 0 0}` to listen on
||| every interface) and runs the event loop, dispatching every
||| incoming request to `handler`. Blocks forever (a plain `main` can
||| just be `serve 8080 myHandler`) -- see the doc for embedding it
||| alongside other work instead.
export
serve : {default (IPv4Addr 127 0 0 1) bindAddr : SocketAddress} -> Port -> Handler -> IO ()
serve {bindAddr} port handler = do
  Just ep <- create
    | Nothing => putStrLn "Network.HTTP.Server.serve: epoll_create failed"
  Right lsock <- socket AF_INET Stream 0
    | Left err => putStrLn "Network.HTTP.Server.serve: socket() failed, errno \{show err}"
  True <- setReuseAddr lsock.descriptor
    | False => putStrLn "Network.HTTP.Server.serve: SO_REUSEADDR failed"
  0 <- bind lsock (Just bindAddr) port
    | err => putStrLn "Network.HTTP.Server.serve: bind() failed, errno \{show err}"
  0 <- listen lsock
    | err => putStrLn "Network.HTTP.Server.serve: listen() failed, errno \{show err}"
  True <- setNonBlocking lsock.descriptor
    | False => putStrLn "Network.HTTP.Server.serve: fcntl(O_NONBLOCK) failed"
  True <- add ep lsock.descriptor epollIn
    | False => putStrLn "Network.HTTP.Server.serve: epoll_ctl(listen) failed"
  connsRef <- newIORef (the (SortedMap Int Conn) empty)
  loop (MkServerState ep lsock connsRef) handler
