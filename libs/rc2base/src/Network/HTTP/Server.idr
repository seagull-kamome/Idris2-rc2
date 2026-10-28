||| A minimal, single-threaded, event-driven HTTP/1.1 server.
||| One `epoll` loop (via `System.Linux.Epoll`) drives everything --
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

import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.String


import public Network.HTTP.Message
import Network.RC2
import Network.Socket
import Network.Socket.Data

import System.Concurrency
import System.Concurrency.RC2
import System.Linux.Epoll
import System.Linux.Eventfd
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc

-- The event loop itself never terminates by construction (`loop`,
-- `acceptLoop`) -- overrides rc2base.ipkg's package-wide `--total`.
%default covering

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
  wake    : FileDesc
  ||| Whether `wake` is still open; guarded by `lock`. `shutdown` closes it, and
  ||| a late `enqueue` / `stop` must not write to a number that may be reused.
  wakeOpen : IORef Bool
  ||| `getThreadId` of the loop thread. `respond` compares against it to
  ||| decide between running inline and handing work to `tasks`.
  loopTid : Int

||| Run `act` with `m` held. `act` must not itself try to acquire `m`
||| (the underlying pthread mutex is not recursive under `--cg rc2`),
||| so anything that re-enters -- running a queued task -- happens after the
||| lock is dropped.
withMutex : Mutex -> IO a -> IO a
withMutex m act = do
  mutexAcquire m
  r <- act
  mutexRelease m
  pure r

||| Write the eventfd so `epollWait` returns, unless `shutdown` closed it. The
||| caller holds `lock`: the write does not wait, and `shutdown` closes the
||| eventfd under the same lock, so no write reaches a reused number.
wakeLoop : ServerCtx -> IO ()
wakeLoop ctx = do
  isOpen <- readIORef ctx.wakeOpen
  when isOpen $ ignore $ eventfdWrite ctx.wake 1

||| Queue `act` to run on the loop thread and wake the loop so it does.
||| The only safe way for a non-loop thread to touch a connection.
enqueue : ServerCtx -> IO () -> IO ()
enqueue ctx act =
  withMutex ctx.lock $ do
    modifyIORef ctx.tasks (act ::)
    wakeLoop ctx

||| Set the stop flag and wake the loop. Idempotent; safe from any thread.
requestStop : ServerCtx -> IO ()
requestStop ctx =
  withMutex ctx.lock $ do
    writeIORef ctx.stopReq True
    wakeLoop ctx

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
-- Connection state
-------------------------------------------------------------------------------

record Conn where
  constructor MkConn
  sock        : Socket
  fd          : FileDesc
  ||| Read accumulator: live bytes are `readBuf[0 .. readLen)`.
  readBuf     : IORef Buffer
  readLen     : IORef Int
  ||| Write accumulator: bytes to send are `writeBuf[0 .. writeLen)`,
  ||| of which `writeBuf[0 .. writeSent)` already went out.
  writeBuf    : IORef Buffer
  writeLen    : IORef Int
  writeSent   : IORef Int
  shouldClose : IORef Bool
  ||| Where the scan of a chunked body that is still arriving stopped.
  chunkMark   : IORef (Maybe ChunkMark)

record ServerState where
  constructor MkServerState
  ctx        : ServerCtx
  epoll      : EPoll
  listenSock : Socket
  listenFd   : FileDesc
  ||| The listener is not watched while `accept` fails for lack of descriptors;
  ||| the next closed connection watches it again.
  listenPaused : IORef Bool
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

%inline %foreign "CExpr:(({ int one = 1; setsockopt($1, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)); })),libc,sys/socket.h"
prim__setReuseAddr : Int32 -> PrimIO Int32

-- So a restarted server can rebind its port at once instead of waiting out `TIME_WAIT`.
setReuseAddr : FileDesc -> IO Bool
setReuseAddr fd = (== 0) <$> primIO (prim__setReuseAddr fd.rawfd)

-- Every socket registered with the `EPoll` must be non-blocking: a blocking
-- `accept` / `recv` / `send` would stall the whole single-threaded loop.
setNonBlocking : FileDesc -> IO Bool
setNonBlocking fd = do
  Right fl <- getStatusFlags fd
    | Left _ => pure False
  Right () <- setStatusFlags fd (fl .|. O_NONBLOCK)
    | Left _ => pure False
  pure True

-- `accept` ran out of descriptors (the process or the system).
isFdExhausted : SocketError -> Bool
isFdExhausted e = let MkErrno m = EMFILE
                      MkErrno n = ENFILE
                  in e == cast m || e == cast n

closeConn : ServerState -> Conn -> IO ()
closeConn st conn = do
  ignore $ epollDel st.epoll conn.fd
  close conn.sock
  modifyIORef st.conns (delete conn.sock.descriptor)
  paused <- readIORef st.listenPaused
  when paused $ do
    writeIORef st.listenPaused False
    ignore $ epollMod st.epoll st.listenFd EPOLLIN

finishWrite : ServerState -> Conn -> IO ()
finishWrite st conn = do
  wantsClose <- readIORef conn.shouldClose
  if wantsClose
    then closeConn st conn
    else ignore $ epollMod st.epoll conn.fd EPOLLIN

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
                    ignore $ epollMod st.epoll conn.fd (EPOLLIN .|. EPOLLOUT)
        Left e =>
          if isWouldBlock e
            then ignore $ epollMod st.epoll conn.fd (EPOLLIN .|. EPOLLOUT)
            else closeConn st conn

-- Append a serialized response to `writeBuf`. `False` if it wouldn't
-- fit under `writeCap` (the connection is then dropped).
appendResponse : Conn -> Response -> IO Bool
appendResponse conn resp = do
  let bodyLen = byteLength resp.body
      head    = responseHead resp
      headLen = stringByteLength head
      -- 1xx, 204 and 304 have no body, whatever the handler gave
      sentLen = if hasBody resp.status then bodyLen else 0
  wlen <- readIORef conn.writeLen
  True <- grow conn.writeBuf (wlen + headLen + sentLen) writeCap
    | False => pure False
  wbuf <- readIORef conn.writeBuf
  setString wbuf wlen head
  when (sentLen > 0) $ copyData resp.body 0 sentLen wbuf (wlen + headLen)
  writeIORef conn.writeLen (wlen + headLen + sentLen)
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
  let bodyStart = headEnd + 4
  case framing hdrs of
    Left _ => closeConn st conn
    Right (Sized need) =>
      when (rlen - bodyStart >= need) $ do
        body <- slice rbuf bodyStart need
        dispatch method path hdrs body (bodyStart + need)
    Right Chunked => do
      mark <- fromMaybe (MkChunkMark bodyStart 0) <$> readIORef conn.chunkMark
      found <- scanChunks Nothing rbuf rlen (st.maxReq - bodyStart) mark
      case found of
        ChunksEnd end size => do
          body <- joinChunks rbuf bodyStart end size
          dispatch method path (decodedHeaders size hdrs) body end
        ChunksMore mark' => writeIORef conn.chunkMark (Just mark')
        _ => closeConn st conn
  where
    dispatch : String -> String -> List (String, String) -> Buffer -> Int -> IO ()
    dispatch method path hdrs' body consumed = do
      writeIORef conn.shouldClose (connectionClose hdrs')
      writeIORef conn.chunkMark Nothing
      dropFront conn consumed
      handler (MkRequest method path hdrs' body Nothing) (respond st conn)
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
  case lookup (cast ev.fd) conns of
    Nothing => pure ()
    Just conn =>
      if hasEvent EPOLLERR ev.events || hasEvent EPOLLHUP ev.events
        then closeConn st conn
        else do
          when (hasEvent EPOLLIN ev.events) $ handleReadable st handler conn
          stillOpen <- isJust . lookup (cast ev.fd) <$> readIORef st.conns
          when (stillOpen && hasEvent EPOLLOUT ev.events) $ flushWrite st conn

-- Level-triggered, so one epoll-reported "listener readable" can hide
-- several pending connections (a burst of clients arriving between
-- `wait` calls) -- drain with `accept` until it reports EAGAIN.
acceptLoop : ServerState -> IO ()
acceptLoop st =
  case !(accept st.listenSock) of
    Left e =>
      -- Out of descriptors: the pending connection keeps the level-triggered
      -- listener ready, so it would spin. Stop watching it until a
      -- connection closes (`closeConn`).
      when (isFdExhausted e) $ do
        writeIORef st.listenPaused True
        ignore $ epollMod st.epoll st.listenFd 0
    Right (csock, _) =>
      case mkFileDesc (cast csock.descriptor) of
        Nothing => close csock >> acceptLoop st
        Just cfd => do
          -- A blocking socket would stall the loop, one the epoll cannot
          -- watch would never be served: drop either.
          True <- setNonBlocking cfd
            | False => close csock >> acceptLoop st
          rbuf <- newBuf initCap
          wbuf <- newBuf initCap
          conn <- MkConn csock cfd
                    <$> newIORef rbuf <*> newIORef 0
                    <*> newIORef wbuf <*> newIORef 0 <*> newIORef 0
                    <*> newIORef False <*> newIORef Nothing
          modifyIORef st.conns (insert csock.descriptor conn)
          Right () <- epollAdd st.epoll cfd EPOLLIN
            | Left _ => closeConn st conn >> acceptLoop st
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
    ignore $ epollDel st.epoll conn.fd
    close conn.sock
  writeIORef st.conns empty
  ignore $ epollDel st.epoll st.listenFd
  close st.listenSock
  withMutex st.ctx.lock $ do
    writeIORef st.ctx.wakeOpen False
    ignore $ close st.ctx.wake
  ignore $ epollClose st.epoll

loop : ServerState -> BoundHandler -> IO ()
loop st handler = do
  Right events <- epollWait st.epoll (-1)
    | Left e => if e == EINTR
                   then loop st handler
                   else putStrLn "Network.HTTP.Server: epoll_wait failed, errno \{show e}" >> shutdown st
  -- The listener goes last: `accept` can hand out the number of a connection
  -- closed a moment ago, and an event of the old one still in this batch
  -- would then hit the new one.
  let (listenEvs, others) = partition (\ev => ev.fd == st.listenFd.rawfd) events
  for_ others $ \ev =>
    if ev.fd == st.ctx.wake.rawfd
      then ignore $ eventfdRead st.ctx.wake
      else handleClientEvent st handler ev
  for_ listenEvs $ \_ => acceptLoop st
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
  Right ep <- epollCreate 64
    | Left e => giveUp [] "epoll_create failed, errno \{show e}"
  Right lsock <- socket AF_INET Stream 0
    | Left err => giveUp [ignore (epollClose ep)] "socket() failed, errno \{show err}"
  let undoSock = [ignore (epollClose ep), close lsock]
  Just lfd <- pure (mkFileDesc (cast lsock.descriptor))
    | Nothing => giveUp undoSock "socket() gave a bad descriptor"
  True <- setReuseAddr lfd
    | False => giveUp undoSock "SO_REUSEADDR failed"
  0 <- bind lsock (Just bindAddr) port
    | err => giveUp undoSock "bind() failed, errno \{show err}"
  0 <- listen lsock
    | err => giveUp undoSock "listen() failed, errno \{show err}"
  True <- setNonBlocking lfd
    | False => giveUp undoSock "fcntl(O_NONBLOCK) failed"
  Right () <- epollAdd ep lfd EPOLLIN
    | Left e => giveUp undoSock "epoll_ctl(listen) failed, errno \{show e}"
  Right wake <- eventfd 0 (EFD_NONBLOCK .|. EFD_CLOEXEC)
    | Left e => giveUp undoSock "eventfd() failed, errno \{show e}"
  Right () <- epollAdd ep wake EPOLLIN
    | Left e => giveUp (undoSock ++ [ignore (close wake)]) "epoll_ctl(eventfd) failed, errno \{show e}"
  lock     <- makeMutex
  tasksRef <- newIORef (the (List (IO ())) [])
  stopRef  <- newIORef False
  loopTid  <- getThreadId
  connsRef <- newIORef (the (SortedMap Int Conn) empty)
  wakeOpen <- newIORef True
  let ctx = MkServerCtx lock tasksRef stopRef wake wakeOpen loopTid
  pausedRef <- newIORef False
  loop (MkServerState ctx ep lsock lfd pausedRef connsRef maxRequestBytes) (handler @{ctx})
  where
    -- Release what was set up so far, then say why `serve` returns.
    giveUp : List (IO ()) -> String -> IO ()
    giveUp undo msg = sequence_ undo >> putStrLn ("Network.HTTP.Server.serve: " ++ msg)
