||| A minimal, single-threaded, event-driven HTTP/1.1 server.
||| One `epoll` loop (via `System.Net.Epoll`) drives everything --
||| accepting connections, parsing requests, and flushing responses --
||| on a single thread. A `Handler` answers through a `respond`
||| continuation rather than a return value, so it can reply either
||| synchronously (call it immediately) or asynchronously (stash it and
||| call it once some other event source is ready) -- including from
||| another thread. A handler can also `stop` the loop. Cross-thread
||| `respond`/`stop` calls are marshalled back onto the loop thread
||| through an eventfd-woken task queue, so the loop itself stays
||| single-threaded.
|||
||| Request and response bodies are raw `Data.Buffer` bytes -- binary
||| safe, no NUL or encoding assumptions. Read/write buffering is done
||| in reused `Buffer`s with offset+length socket IO (`Network.RC2`), no
||| per-chunk copy. See `libs/rc2base/doc/http-server.md` for the
||| design, wire-format subset supported, and known limitations.
module Network.HTTP.Server

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import Data.IORef
import Data.Maybe
import Data.SortedMap
import Data.String

import Network.RC2
import Network.Socket
import Network.Socket.Data

import System.Concurrency
import System.Concurrency.RC2
import System.Net.Epoll

-- The event loop itself never terminates by construction (`loop`,
-- `acceptLoop`), and the byte-scanning parser helpers loop on an `Int`
-- index rather than structurally -- overrides rc2base.ipkg's
-- package-wide `--total`.
%default covering

-------------------------------------------------------------------------------
-- Byte buffers: the currency for request/response bodies
-------------------------------------------------------------------------------

-- Pure: reads the buffer's own size header (`getBufferSize`). A body is
-- just a `Buffer`, with no separate length field to fall out of sync --
-- its length is always exactly this.
%foreign "scheme:blodwen-buffer-size"
         "RefC:getBufferSize"
prim__bufLen : Buffer -> Int

||| Byte length of a `Buffer` (its allocated size).
export
byteLength : Buffer -> Int
byteLength = prim__bufLen

-- `newBuffer` only rejects a negative size (`Data.Buffer`'s own guard),
-- so with a clamped `n` the `Nothing` case is unreachable -- crash
-- rather than thread `Maybe` through every allocation. Same shape as
-- `Network.Socket.sendBytes`'s own handling of this.
newBuf : HasIO io => Int -> io Buffer
newBuf n = do
  Just b <- newBuffer (max 0 n)
    | Nothing => assert_total $ idris_crash "Network.HTTP.Server.newBuf: newBuffer failed on a non-negative size"
  pure b

||| UTF-8-encode `s` into a fresh, exactly-sized `Buffer`. A stopgap for
||| building `Response` bodies until richer helpers land; `s` must not
||| contain a NUL byte (the length is computed with `strlen`).
export
fromString : HasIO io => String -> io Buffer
fromString s = do
  let n = stringByteLength s
  b <- newBuf n
  setString b 0 s
  pure b

||| Decode a whole `Buffer` as one UTF-8 `String`. Only meaningful for a
||| body already known to be text -- binary bytes round-trip lossily.
export
toString : HasIO io => Buffer -> io String
toString b = getString b 0 (byteLength b)

-- A fresh `len`-byte buffer holding `src[off .. off+len)`.
slice : HasIO io => Buffer -> (off, len : Int) -> io Buffer
slice src off len = do
  b <- newBuf len
  when (len > 0) $ copyData src off len b 0
  pure b

-- Starting size of a connection's read/write accumulators.
initCap : Int
initCap = 4096

-- Ensure `!ref`'s backing buffer holds at least `need` bytes,
-- reallocating (roughly doubling, clamped to `cap`) if not. `False`
-- means `need` exceeds `cap` and `!ref` is left untouched.
grow : (ref : IORef Buffer) -> (need, cap : Int) -> IO Bool
grow ref need cap = do
  cur <- readIORef ref
  let have = byteLength cur
  if need <= have
    then pure True
    else if need > cap
      then pure False
      else do
        bigger <- newBuf (min cap (max need (have * 2)))
        when (have > 0) $ copyData cur 0 have bigger 0
        writeIORef ref bigger
        pure True

-------------------------------------------------------------------------------
-- Requests and responses
-------------------------------------------------------------------------------

||| A parsed HTTP/1.1 request. `path` is passed through verbatim,
||| query string and all -- no URL-decoding or splitting. `body` is the
||| raw bytes (`byteLength body` bytes of them); `toString body`
||| decodes it as text.
public export
record Request where
  constructor MkRequest
  method  : String
  path    : String
  headers : List (String, String)
  body    : Buffer

||| A `Handler`'s answer, passed to its `respond` continuation.
||| `Content-Length` is computed from `body` (`byteLength`) and added
||| automatically -- don't set it in `headers`. Build one directly with
||| `MkResponse` and a `Buffer` body, or use the `Response.*`
||| constructors below (`Response.text`, `Response.ok`, ...).
public export
record Response where
  constructor MkResponse
  status  : Int
  headers : List (String, String)
  body    : Buffer

||| Convenience constructors. Common enough names (`text`, `ok`, ...)
||| that they live under the `Response` namespace -- call them bare when
||| that's unambiguous, `Response.text` etc. when it isn't. Each takes
||| an optional `headers` (a `(name, value)` list) as a leading implicit
||| with a `[]` default; a `Content-Type` is prepended where noted.
namespace Response

  ||| `status` with `body` and an explicit `Content-Type`. Pure -- the
  ||| caller already has the bytes.
  export
  bytes : {default [] headers : List (String, String)}
       -> (status : Int) -> (contentType : String) -> Buffer -> Response
  bytes {headers} status contentType body =
    MkResponse status (("Content-Type", contentType) :: headers) body

  ||| `status` with an empty body and no `Content-Type` -- 204, a 3xx
  ||| redirect (add `Location` via `headers`), 304, ...
  export
  noBody : {default [] headers : List (String, String)} -> (status : Int) -> IO Response
  noBody {headers} status = MkResponse status headers <$> newBuf 0

  ||| `status` with a `text/plain; charset=utf-8` body.
  export
  text : {default [] headers : List (String, String)} -> (status : Int) -> String -> IO Response
  text {headers} status body = do
    b <- fromString body
    pure (bytes {headers} status "text/plain; charset=utf-8" b)

  ||| `status` with a `text/html; charset=utf-8` body.
  export
  html : {default [] headers : List (String, String)} -> (status : Int) -> String -> IO Response
  html {headers} status body = do
    b <- fromString body
    pure (bytes {headers} status "text/html; charset=utf-8" b)

  ||| `text` at a fixed status: 200 / 201 / 400 / 404 / 500.
  export
  ok, created, badRequest, notFound, serverError
    : {default [] headers : List (String, String)} -> String -> IO Response
  ok          {headers} = text {headers} 200
  created     {headers} = text {headers} 201
  badRequest  {headers} = text {headers} 400
  notFound    {headers} = text {headers} 404
  serverError {headers} = text {headers} 500

-------------------------------------------------------------------------------
-- Server handle: cross-thread response delivery and shutdown
-------------------------------------------------------------------------------

||| An opaque handle to the running server. There is exactly one per
||| `serve` call, so it is threaded to every `Handler` as an *auto-
||| implicit* rather than a named argument -- handler code never has to
||| carry it around, it just calls `stop` and the enclosing `Handler`'s
||| own auto-implicit satisfies the search. To stop from another thread,
||| capture `stop` (or, if you must, the `ServerCtx` itself) into that
||| thread the same way you would `respond`.
export
record ServerCtx where
  constructor MkServerCtx
  ||| Guards `tasks` and `stopReq`.
  lock    : Mutex
  ||| Closures the loop thread must run (socket I/O, epoll edits) on
  ||| behalf of other threads. Stored newest-first; reversed when drained.
  tasks   : IORef (List (IO ()))
  stopReq : IORef Bool
  ||| epoll-registered eventfd: any thread writes it to break the loop
  ||| out of `wait`.
  wake    : EventFd
  ||| `getThreadId` of the loop thread. `respond` compares against it to
  ||| decide between running inline and handing work to `tasks`.
  loopTid : Int

||| Run `act` with `m` held. `act` must not itself try to acquire `m`
||| (the underlying pthread mutex is not recursive under `--cg rc2`),
||| so anything that re-enters -- running a queued task, signalling the
||| eventfd -- happens after the lock is dropped.
withMutex : Mutex -> IO a -> IO a
withMutex m act = do
  mutexAcquire m
  r <- act
  mutexRelease m
  pure r

||| Queue `act` to run on the loop thread and wake the loop so it does.
||| The only safe way for a non-loop thread to touch a connection.
enqueue : ServerCtx -> IO () -> IO ()
enqueue ctx act = do
  withMutex ctx.lock $ modifyIORef ctx.tasks (act ::)
  ignore $ signalEventFd ctx.wake

||| Set the stop flag and wake the loop. Idempotent; safe from any thread.
requestStop : ServerCtx -> IO ()
requestStop ctx = do
  withMutex ctx.lock $ writeIORef ctx.stopReq True
  ignore $ signalEventFd ctx.wake

||| Ask the event loop to stop. Safe synchronously from a `Handler`, or
||| from any other thread (one the handler forked, say). The loop
||| finishes its current iteration -- flushing responses already queued
||| -- then closes every connection, the listening socket, and its own
||| epoll/eventfd descriptors, and `serve` returns. Idempotent.
export
stop : (ctx : ServerCtx) => IO ()
stop = requestStop ctx

||| A request handler. Call the `respond` continuation exactly once --
||| synchronously, or later from any IO action including one on another
||| thread (`respond` is safe from anywhere; see the module doc). Calling
||| it more than once, or not at all, leaves the connection in an
||| unspecified state. `stop` (resolved from the auto-implicit
||| `ServerCtx`) ends the server.
public export
Handler : Type
Handler = ServerCtx => Request -> (Response -> IO ()) -> IO ()

-- `Handler` with its `ServerCtx` already supplied. `serve` applies the
-- auto-implicit once, up front; the event loop threads this plain type
-- around so the implicit never has to be re-solved (and can't turn
-- ambiguous) at each internal call site.
BoundHandler : Type
BoundHandler = Request -> (Response -> IO ()) -> IO ()

-------------------------------------------------------------------------------
-- Minimal HTTP/1.1 wire format
-------------------------------------------------------------------------------

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
reasonPhrase 413 = "Payload Too Large"
reasonPhrase 500 = "Internal Server Error"
reasonPhrase 501 = "Not Implemented"
reasonPhrase 503 = "Service Unavailable"
reasonPhrase _   = "Unknown"

contentLength : List (String, String) -> Int
contentLength hdrs = fromMaybe 0 (lookup "content-length" hdrs >>= parsePositive {a = Int})

-- HTTP/1.1 defaults to keep-alive; only an explicit "Connection: close"
-- ends it. HTTP/1.0 (which defaults the other way) isn't supported --
-- see the doc's "Scope" section.
connectionClose : List (String, String) -> Bool
connectionClose hdrs = maybe False ((== "close") . toLower . trim) (lookup "connection" hdrs)

-- The status line + header lines + Content-Length + terminating CRLF,
-- as one ASCII string. Header keys/values are assumed ASCII (RFC 7230);
-- a non-ASCII or NUL byte in one corrupts the framing.
responseHead : Response -> (bodyLen : Int) -> String
responseHead resp bodyLen =
    "HTTP/1.1 " ++ show resp.status ++ " " ++ reasonPhrase resp.status ++ "\r\n"
    ++ concatMap headerLine resp.headers
    ++ "Content-Length: " ++ show bodyLen ++ "\r\n\r\n"
  where
    headerLine : (String, String) -> String
    headerLine (k, v) = k ++ ": " ++ v ++ "\r\n"

-------------------------------------------------------------------------------
-- Byte-scanning request parser (operates on the read accumulator's
-- bytes; only the final method/path/header-key/header-value substrings
-- are lifted to `String`, each on its own -- never one big head string)
-------------------------------------------------------------------------------

byteAt : Buffer -> Int -> IO Int
byteAt b i = cast <$> getBits8 b i

-- Index of the CR of the first "\r\n\r\n" in `b[0 .. n)`, else Nothing.
findHeadEnd : Buffer -> (n : Int) -> IO (Maybe Int)
findHeadEnd b n = go 0
  where
    go : Int -> IO (Maybe Int)
    go i =
      if i + 3 >= n then pure Nothing
        else do
          a <- byteAt b i
          if a /= 13
            then go (i + 1)
            else do
              c <- byteAt b (i + 1)
              d <- byteAt b (i + 2)
              e <- byteAt b (i + 3)
              if c == 10 && d == 13 && e == 10 then pure (Just i) else go (i + 1)

-- Index of the CR of the next CRLF at/after `i`, capped at `limit`
-- (returned as-is when there is no CRLF before it).
lineEnd : Buffer -> (i, limit : Int) -> IO Int
lineEnd b i limit = go i
  where
    go : Int -> IO Int
    go j =
      if j + 1 >= limit then pure limit
        else do
          a <- byteAt b j
          if a == 13
            then do c <- byteAt b (j + 1)
                    if c == 10 then pure j else go (j + 1)
            else go (j + 1)

-- First non-(SP) index at/after `i`, capped at `limit`.
skipSp : Buffer -> (i, limit : Int) -> IO Int
skipSp b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 32 then skipSp b (i + 1) limit else pure i

-- First SP index at/after `i`, capped at `limit`.
spanTok : Buffer -> (i, limit : Int) -> IO Int
spanTok b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 32 then pure i else spanTok b (i + 1) limit

-- Index of the first ':' at/after `i`, capped at `limit`.
colonAt : Buffer -> (i, limit : Int) -> IO Int
colonAt b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 58 then pure i else colonAt b (i + 1) limit

-- Shrink `[lo, hi)` past leading and trailing SP/HTAB.
trimRange : Buffer -> (lo, hi : Int) -> IO (Int, Int)
trimRange b lo hi = do
  lo' <- fwd lo
  hi' <- bwd hi
  pure (lo', max lo' hi')
  where
    fwd : Int -> IO Int
    fwd i = if i >= hi then pure hi
              else do a <- byteAt b i
                      if a == 32 || a == 9 then fwd (i + 1) else pure i
    bwd : Int -> IO Int
    bwd i = if i <= lo then pure lo
              else do a <- byteAt b (i - 1)
                      if a == 32 || a == 9 then bwd (i - 1) else pure i

-- One header line `b[ls, le)` -> (lowercased key, trimmed value).
-- `Nothing` for a line with no ':' (skipped, not fatal).
parseHeaderLine : Buffer -> (ls, le : Int) -> IO (Maybe (String, String))
parseHeaderLine b ls le = do
  c <- colonAt b ls le
  if c >= le
    then pure Nothing
    else do
      (ks, ke) <- trimRange b ls c
      (vs, ve) <- trimRange b (c + 1) le
      key <- getString b ks (ke - ks)
      val <- getString b vs (ve - vs)
      pure (Just (toLower key, val))

-- Request line + all header lines from `b[0, headEnd)`.
-- `Nothing` = malformed request line (caller closes the connection).
parseHead : Buffer -> (headEnd : Int) -> IO (Maybe (String, String, List (String, String)))
parseHead b headEnd = do
  rlEnd <- lineEnd b 0 headEnd
  m0 <- skipSp b 0 rlEnd
  m1 <- spanTok b m0 rlEnd
  p0 <- skipSp b m1 rlEnd
  p1 <- spanTok b p0 rlEnd
  if m1 <= m0 || p1 <= p0
    then pure Nothing
    else do
      method <- getString b m0 (m1 - m0)
      path   <- getString b p0 (p1 - p0)
      hdrs   <- collect (rlEnd + 2) []
      pure (Just (method, path, reverse hdrs))
  where
    collect : Int -> List (String, String) -> IO (List (String, String))
    collect i acc =
      if i >= headEnd then pure acc
        else do
          le  <- lineEnd b i headEnd
          mkv <- parseHeaderLine b i le
          collect (le + 2) (maybe acc (:: acc) mkv)

-------------------------------------------------------------------------------
-- Connection state
-------------------------------------------------------------------------------

record Conn where
  constructor MkConn
  sock        : Socket
  ||| Read accumulator: live bytes are `readBuf[0 .. readLen)`.
  readBuf     : IORef Buffer
  readLen     : IORef Int
  ||| Write accumulator: bytes to send are `writeBuf[0 .. writeLen)`,
  ||| of which `writeBuf[0 .. writeSent)` already went out.
  writeBuf    : IORef Buffer
  writeLen    : IORef Int
  writeSent   : IORef Int
  shouldClose : IORef Bool

record ServerState where
  constructor MkServerState
  ctx        : ServerCtx
  epoll      : EPoll
  listenSock : Socket
  conns      : IORef (SortedMap Int Conn)
  ||| Ceiling on one connection's read accumulator (header + body). A
  ||| request that would push past it has its connection dropped.
  maxReq     : Int

-- Ceiling on a connection's write accumulator. Responses are
-- handler-built (trusted), so this is only a runaway backstop.
writeCap : Int
writeCap = 67108864

-- Bytes per recv()/send() syscall.
ioChunk : Int
ioChunk = 65536

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

-- Send as much of `writeBuf[writeSent .. writeLen)` as the socket
-- takes; on a short write, advance `writeSent` and keep `EPOLLOUT`
-- armed so the rest goes out on the next writable event.
flushWrite : ServerState -> Conn -> IO ()
flushWrite st conn = do
  wlen  <- readIORef conn.writeLen
  wsent <- readIORef conn.writeSent
  let left = wlen - wsent
  if left <= 0
    then do writeIORef conn.writeLen 0
            writeIORef conn.writeSent 0
            finishWrite st conn
    else do
      wbuf <- readIORef conn.writeBuf
      case !(sendBuf conn.sock wbuf wsent (min ioChunk left)) of
        Right n =>
          if n >= left
            then do writeIORef conn.writeLen 0
                    writeIORef conn.writeSent 0
                    finishWrite st conn
            else do writeIORef conn.writeSent (wsent + n)
                    ignore $ modify st.epoll conn.sock.descriptor (epollIn <+> epollOut)
        Left e =>
          if isWouldBlock e
            then ignore $ modify st.epoll conn.sock.descriptor (epollIn <+> epollOut)
            else closeConn st conn

-- Append a serialized response to `writeBuf`. `False` if it wouldn't
-- fit under `writeCap` (the connection is then dropped).
appendResponse : Conn -> Response -> IO Bool
appendResponse conn resp = do
  let bodyLen = byteLength resp.body
      head    = responseHead resp bodyLen
      headLen = stringByteLength head
  wlen <- readIORef conn.writeLen
  True <- grow conn.writeBuf (wlen + headLen + bodyLen) writeCap
    | False => pure False
  wbuf <- readIORef conn.writeBuf
  setString wbuf wlen head
  when (bodyLen > 0) $ copyData resp.body 0 bodyLen wbuf (wlen + headLen)
  writeIORef conn.writeLen (wlen + headLen + bodyLen)
  pure True

-- The actual write, always run on the loop thread. `st.conns` is
-- re-checked here (not just at dispatch time) because this can run
-- much later than the request it answers -- an async handler may
-- stash it past several other events, by which point the client
-- could already be gone.
deliver : ServerState -> Conn -> Response -> IO ()
deliver st conn resp = do
  conns <- readIORef st.conns
  when (isJust (lookup conn.sock.descriptor conns)) $ do
    ok <- appendResponse conn resp
    if ok then flushWrite st conn else closeConn st conn

-- The `respond` continuation handed to a `Handler`. A synchronous
-- handler runs on the loop thread, so `deliver` fires inline. Anything
-- else -- a `forkJoin`ed thread, a callback that lands on some other
-- thread -- must not touch the socket or epoll directly (that would
-- race the loop), so it hands `deliver` to the loop thread via the
-- task queue and wakes it.
respond : ServerState -> Conn -> Response -> IO ()
respond st conn resp = do
  tid <- getThreadId
  if tid == st.ctx.loopTid
    then deliver st conn resp
    else enqueue st.ctx (deliver st conn resp)

-- Shift `readBuf[k .. readLen)` down to offset 0 and drop `k` from
-- `readLen`. Via a temp buffer -- `copyData`'s overlap behaviour isn't
-- guaranteed, and the leftover (a pipelined next request) is small.
dropFront : Conn -> (k : Int) -> IO ()
dropFront conn k = do
  rlen <- readIORef conn.readLen
  let rest = rlen - k
  if rest <= 0
    then writeIORef conn.readLen 0
    else do
      rbuf <- readIORef conn.readBuf
      tmp  <- slice rbuf k rest
      copyData tmp 0 rest rbuf 0
      writeIORef conn.readLen rest

-- Recurses so one `recv` that happens to land two full requests in the
-- same TCP segment (or a genuinely pipelined client) doesn't strand
-- the second one waiting for a read event that may never come.
tryDispatch : ServerState -> BoundHandler -> Conn -> IO ()
tryDispatch st handler conn = do
  rbuf <- readIORef conn.readBuf
  rlen <- readIORef conn.readLen
  Just headEnd <- findHeadEnd rbuf rlen
    | Nothing => pure ()
  Just (method, path, hdrs) <- parseHead rbuf headEnd
    | Nothing => closeConn st conn
  let need      = contentLength hdrs
      bodyStart = headEnd + 4
  if rlen - bodyStart < need
    then pure ()
    else do
      body <- slice rbuf bodyStart need
      writeIORef conn.shouldClose (connectionClose hdrs)
      dropFront conn (bodyStart + need)
      handler (MkRequest method path hdrs body) (respond st conn)
      tryDispatch st handler conn

handleReadable : ServerState -> BoundHandler -> Conn -> IO ()
handleReadable st handler conn = do
  rlen <- readIORef conn.readLen
  let room = st.maxReq - rlen
  if room <= 0
    then closeConn st conn
    else do
      let want = min ioChunk room
      True <- grow conn.readBuf (rlen + want) st.maxReq
        | False => closeConn st conn
      rbuf <- readIORef conn.readBuf
      case !(recvBuf conn.sock rbuf rlen want) of
        Right 0 => closeConn st conn
        Right n => do
          writeIORef conn.readLen (rlen + n)
          tryDispatch st handler conn
        Left e  => if isWouldBlock e then pure () else closeConn st conn

handleClientEvent : ServerState -> BoundHandler -> ReadyEvent -> IO ()
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
      rbuf <- newBuf initCap
      wbuf <- newBuf initCap
      conn <- MkConn csock
                <$> newIORef rbuf <*> newIORef 0
                <*> newIORef wbuf <*> newIORef 0 <*> newIORef 0
                <*> newIORef False
      modifyIORef st.conns (insert csock.descriptor conn)
      ignore $ add st.epoll csock.descriptor epollIn
      acceptLoop st

-- Run everything other threads have queued for us, oldest first
-- (`enqueue` pushes newest-first). The list is swapped out under the
-- lock and run without it held, so a task that itself calls `enqueue`
-- or `stop` doesn't deadlock -- it just lands in the next batch.
drainTasks : ServerState -> IO ()
drainTasks st = do
  pending <- withMutex st.ctx.lock $ do
    ts <- readIORef st.ctx.tasks
    writeIORef st.ctx.tasks []
    pure ts
  sequence_ (reverse pending)

-- Tear down for good: every connection, the listener, then our own
-- epoll and eventfd descriptors. After this `loop` returns and so does
-- `serve`.
shutdown : ServerState -> IO ()
shutdown st = do
  conns <- readIORef st.conns
  for_ (values conns) $ \conn => do
    ignore $ remove st.epoll conn.sock.descriptor
    close conn.sock
  writeIORef st.conns empty
  ignore $ remove st.epoll st.listenSock.descriptor
  close st.listenSock
  ignore $ closeEventFd st.ctx.wake
  ignore $ closeEpoll st.epoll

loop : ServerState -> BoundHandler -> IO ()
loop st handler = do
  events <- wait st.epoll (-1)
  for_ events $ \ev =>
    if ev.fd == st.listenSock.descriptor
      then acceptLoop st
      else if ev.fd == st.ctx.wake.fd
        then ignore $ drainEventFd st.ctx.wake
        else handleClientEvent st handler ev
  drainTasks st
  stopping <- withMutex st.ctx.lock (readIORef st.ctx.stopReq)
  if stopping
    then shutdown st
    else loop st handler

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

||| Listens on `port` (on `bindAddr`, `localhost` unless given
||| explicitly -- pass e.g. `{bindAddr = IPv4Addr 0 0 0 0}` to listen on
||| every interface) and runs the event loop, dispatching every
||| incoming request to `handler`. `maxRequestBytes` (default 8 MiB)
||| caps one connection's accumulated header+body; a request that would
||| exceed it has its connection closed with no response. Blocks until a
||| `Handler` (or a thread one of them handed `ctx.stop` to) stops the
||| loop; a plain `main` that never stops can just be
||| `serve 8080 myHandler` -- see the doc for embedding it alongside
||| other work instead.
export
serve : {default (IPv4Addr 127 0 0 1) bindAddr : SocketAddress}
     -> {default 8388608 maxRequestBytes : Int}
     -> Port -> Handler -> IO ()
serve {bindAddr} {maxRequestBytes} port handler = do
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
  Just wake <- createEventFd
    | Nothing => putStrLn "Network.HTTP.Server.serve: eventfd() failed"
  True <- add ep wake.fd epollIn
    | False => putStrLn "Network.HTTP.Server.serve: epoll_ctl(eventfd) failed"
  lock     <- makeMutex
  tasksRef <- newIORef (the (List (IO ())) [])
  stopRef  <- newIORef False
  loopTid  <- getThreadId
  connsRef <- newIORef (the (SortedMap Int Conn) empty)
  let ctx = MkServerCtx lock tasksRef stopRef wake loopTid
  loop (MkServerState ctx ep lsock connsRef maxRequestBytes) (handler @{ctx})
