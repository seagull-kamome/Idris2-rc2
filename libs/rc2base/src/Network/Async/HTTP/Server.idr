||| An HTTP/1.1 server written as `Control.Task` tasks over `Network.Async`:
||| one task accepts, and each connection is a task of its own that reads a
||| request, runs the handler and writes the response, over and over until the
||| client leaves. A `Handler` is a function to a `Task`, so it can wait for a
||| timer, another socket, a `Promise` or an io_uring request before it answers,
||| with no continuation to carry around. The messages and their parser are
||| those of `Network.HTTP.Message`. Needs no liburing.
module Network.Async.HTTP.Server

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import public Network.HTTP.Message

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.IORef
import Data.String
import Data.Either
import Network.Async
import public Network.Socket.Data
import System.Posix.Errno

%default covering

||| Answers a request. It runs in the task of its connection, so the next
||| request of that connection waits for the answer.
public export
Handler : Type
Handler = Request -> Task Response

||| What one connection may make the server hold, and for how long. A time of 0
||| is no limit.
public export
record Limits where
  constructor MkLimits
  ||| The request line and the headers together: a longer head is answered with 431.
  maxHeadBytes : Int
  ||| The head and the body together: a larger request is answered with 413.
  maxRequestBytes : Int
  ||| How long a connection may wait, in milliseconds, for the first byte of a
  ||| request (the first one, or the next one on a kept-alive connection): after that
  ||| the connection is closed.
  idleTimeoutMs : Nat
  ||| How long a request may take to arrive, in milliseconds, from its first byte to
  ||| its last (all of one deadline, not a time per read, so a client that sends a
  ||| byte at a time does not keep the connection): after that it is answered with
  ||| 408 and the connection is closed. The handler's time is not counted.
  requestTimeoutMs : Nat
  ||| How long a response may take to be sent, in milliseconds: after that the
  ||| connection is closed.
  writeTimeoutMs : Nat
  ||| How many connections are served at once (0: no limit). One more is
  ||| answered with 503 and closed. Each connection may hold up to
  ||| `maxRequestBytes`, so without a limit enough slow clients make the server
  ||| hold that much each (or use up its descriptors).
  maxConnections : Nat

||| 64 KiB for the head, 8 MiB for the request; 60 s idle, 30 s for a request to
||| arrive and 30 s for a response to go out; 1024 connections at once.
export
defaultLimits : Limits
defaultLimits = MkLimits 65536 8388608 60000 30000 30000 1024

-- Bytes asked of one `recv`.
chunk : Int
chunk = 65536

-- The status line, the headers and the body, in one buffer. The response to HEAD
-- has the head of the response to GET and no body, as have 1xx, 204 and 304.
encode : (headOnly : Bool) -> Response -> IO Buffer
encode headOnly resp = do
  let bodyLen = byteLength resp.body
  let head = responseHeadFor headOnly resp
  let headLen = stringByteLength head
  let sent = if hasBody resp.status && not headOnly then bodyLen else 0
  out <- newBuf (headLen + sent)
  setString out 0 head
  when (sent > 0) $ copyData resp.body 0 sent out headLen
  pure out

-- The request line and the headers of a request, and how its body is delimited.
record Head where
  constructor MkHead
  method : String
  path : String
  headers : List (String, String)
  http10 : Bool
  bodyStart : Int
  bodyFraming : Framing

-- What a read gave.
data Read = Got Buffer Int | Gone | TimedOut

-- Serve one connection until the client leaves or asks to close. What cannot be
-- served is answered and the connection closed: 400 for a head or framing that
-- cannot be read, 408 for a request that took too long to arrive, 413 for a
-- request over the limit, 417 for an expectation other than 100-continue, 431
-- for a head over it, 501 for a transfer coding other than chunked.
connection : Limits -> Handler -> Sock -> Task ()
connection limits handler conn = do
  buf <- liftIO (newBuf initCap)
  deadline <- startDeadline 0
  readHead buf 0 0 deadline
  where
    -- The head has to fit in what a request may take up, as well as in its own limit.
    headLimit : Int
    headLimit = min limits.maxHeadBytes limits.maxRequestBytes

    -- The time at which a limit of `ms` milliseconds, starting now, runs out.
    after : Nat -> Task (Maybe Time)
    after Z = pure Nothing
    after ms = (\t => Just (t + ms)) <$> now

    -- The deadline for what is read next: the idle time while nothing of a
    -- request has arrived (`len`), the time of a request when some has.
    startDeadline : (len : Int) -> Task (Maybe Time)
    startDeadline len = after (if len > 0 then limits.requestTimeoutMs else limits.idleTimeoutMs)

    -- The task, given up if there is a deadline and it passes first.
    within : Maybe Time -> Task a -> Task (Maybe a)
    within Nothing task = Just <$> task
    within (Just t) task = timeoutAt t task

    readHead : Buffer -> (len, scanned : Int) -> (deadline : Maybe Time) -> Task ()
    gotHead : Buffer -> (len, headEnd : Int) -> (deadline : Maybe Time) -> Task ()
    expecting : Buffer -> (len : Int) -> Head -> (deadline : Maybe Time) -> Task ()
    readBody : Buffer -> (len : Int) -> Head -> (deadline : Maybe Time) -> Task ()
    readChunks : Buffer -> (len : Int) -> Head -> ChunkMark -> (deadline : Maybe Time) -> Task ()
    serveRequest : Buffer -> (len, reqEnd : Int) -> Head -> Buffer -> Task ()

    -- Send the bytes; whether they went out in time.
    sendOut : Buffer -> Task Bool
    sendOut out = do
      sent <- case limits.writeTimeoutMs of
                Z => Just <$> sendAll conn out 0 (byteLength out)
                ms => (\t => sendAllUntil t conn out 0 (byteLength out)) =<< map (+ ms) now
      pure (maybe False isRight sent)

    reply : (headOnly : Bool) -> Response -> Task Bool
    reply headOnly resp = liftIO (encode headOnly resp) >>= sendOut

    -- Answer what cannot be served and let the connection end, lingering
    -- (`doc/async-http-server.md`).
    refuse : Int -> String -> Task ()
    refuse status message = do
      resp <- liftIO (text {headers = [("Connection", "close")]} status message)
      sent <- reply False resp
      when sent $ do
        onReactor (shutdownWrite conn)
        deadline <- after 1000
        ignore (within deadline (discard conn 262144))

    -- Read at most `want` more bytes after the `len` that `buf` holds, before the deadline.
    more : Maybe Time -> Buffer -> (len, want : Int) -> Task Read
    more deadline buf len want = do
      Just buf' <- onReactor (growBuffer buf (len + want) limits.maxRequestBytes)
        | Nothing => pure Gone
      r <- maybe (Just <$> recv conn buf' len want) (\t => recvUntil t conn buf' len want) deadline
      pure $ case r of
        Nothing => TimedOut
        Just (Right n) => if n > 0 then Got buf' (len + n) else Gone
        Just (Left _) => Gone

    -- What a request that did not arrive in time is answered with. (Nothing, if no
    -- request had started: the connection was only idle.)
    timedOut : (len : Int) -> Task ()
    timedOut len = when (len > 0) (refuse 408 "request timeout\n")

    -- `buf[0 .. len)` is what has been read and not yet answered; the head
    -- does not end before `scanned`.
    readHead buf len scanned deadline = do
      found <- onReactor (findHeadEndFrom buf scanned len)
      case found of
        Just headEnd => if headEnd + 4 > headLimit
                          then refuse 431 "request header fields too large\n"
                          else gotHead buf len headEnd deadline
        Nothing => if len >= headLimit
                     then refuse 431 "request header fields too large\n"
                     else do
                       r <- more deadline buf len (min chunk (headLimit - len))
                       case r of
                         Gone => pure ()
                         TimedOut => timedOut len
                         Got buf' len' => do
                           -- the first byte of a request starts its time
                           deadline' <- if len == 0 then startDeadline len' else pure deadline
                           readHead buf' len' (max 0 (len - 3)) deadline'

    gotHead buf len headEnd deadline = do
      parsed <- onReactor (parseRequestHead buf headEnd)
      case parsed of
        Nothing => refuse 400 "bad request\n"
        Just (method, path, version, hdrs) => case version of
          "HTTP/1.1" => framed method path hdrs False
          "HTTP/1.0" => framed method path hdrs True
          _ => if isPrefixOf "HTTP/" version then refuse 505 "http version not supported\n"
               else refuse 400 "bad request\n"
      where
        -- The framing headers can be trusted and the request is not too large.
        framed : (method, path : String) -> List (String, String) -> (http10 : Bool) -> Task ()
        framed method path hdrs http10 = case framing hdrs of
          Left Malformed => refuse 400 "bad request\n"
          Left UnsupportedCoding => refuse 501 "transfer coding not implemented\n"
          Right Chunked =>
            if http10 then refuse 400 "bad request\n"
            else expecting buf len (MkHead method path hdrs http10 (headEnd + 4) Chunked) deadline
          Right fr@(Sized size) =>
            if size > limits.maxRequestBytes - (headEnd + 4) then refuse 413 "payload too large\n"
            else expecting buf len (MkHead method path hdrs http10 (headEnd + 4) fr) deadline

    -- A client that expects `100 Continue` waits for it before it sends the body
    -- (RFC 9110, 10.1.1); HTTP/1.0 has no such response.
    expecting buf len head deadline = case expectation head.headers of
      ExpectUnmet => refuse 417 "expectation failed\n"
      ExpectContinue =>
        if head.http10 || not (awaiting head) then readBody buf len head deadline
        else do
          sent <- liftIO (fromString continueHead) >>= sendOut
          when sent (readBody buf len head deadline)
      NoExpectation => readBody buf len head deadline
      where
        awaiting : Head -> Bool
        awaiting (MkHead _ _ _ _ start (Sized size)) = len < start + size
        awaiting (MkHead _ _ _ _ start Chunked) = len <= start

    readBody buf len head deadline = case head.bodyFraming of
      Chunked => readChunks buf len head (MkChunkMark head.bodyStart 0) deadline
      Sized size =>
        if len >= head.bodyStart + size
          then liftIO (slice buf head.bodyStart size) >>= serveRequest buf len (head.bodyStart + size) head
          else do
            r <- more deadline buf len (min chunk (head.bodyStart + size - len))
            case r of
              Gone => pure ()
              TimedOut => timedOut len
              Got buf' len' => readBody buf' len' head deadline

    readChunks buf len head mark deadline = do
      found <- liftIO (scanChunks Nothing buf len (limits.maxRequestBytes - head.bodyStart) mark)
      case found of
        ChunksBad => refuse 400 "bad request\n"
        ChunksTooLarge => refuse 413 "payload too large\n"
        ChunksEnd reqEnd size => do
          body <- liftIO (joinChunks buf head.bodyStart reqEnd size)
          serveRequest buf len reqEnd ({ headers := decodedHeaders size head.headers } head) body
        ChunksMore mark' =>
          if len >= limits.maxRequestBytes then refuse 413 "payload too large\n"
          else do
            r <- more deadline buf len (min chunk (limits.maxRequestBytes - len))
            case r of
              Gone => pure ()
              TimedOut => timedOut len
              Got buf' len' => readChunks buf' len' head mark' deadline

    serveRequest buf len reqEnd head body = do
      resp <- handler (MkRequest head.method head.path head.headers body conn.peer)
      -- HTTP/1.0 ends the connection unless the request asked to keep it
      let closing = connectionClose head.headers || closes resp
                    || (head.http10 && not (connectionKeepAlive head.headers))
      sent <- reply (head.method == "HEAD")
                    (if closing then closeAfter resp else if head.http10 then keepAliveAfter resp else resp)
      when (sent && not closing) $ do
        rest <- liftIO (if len == reqEnd then pure buf else slice buf reqEnd (len - reqEnd))
        deadline <- startDeadline (len - reqEnd)
        readHead rest (len - reqEnd) 0 deadline

-- `accept` ran out of descriptors or memory: the pending connection stays, so
-- retrying at once would spin.
exhausted : Errno -> Bool
exhausted e = elem e [EMFILE, ENFILE, ENOBUFS, ENOMEM]

-- `accept` reports a failure of the connection it was about to return (or of
-- the network); the next call is not affected (accept(2), "Error handling").
transient : Errno -> Bool
transient e = elem e [ECONNABORTED, EPROTO, ENETDOWN, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, ENETUNREACH]

||| Accept connections from `listener` and serve each in a task of its own.
||| Never ends unless `accept` fails for good, which is the result. The
||| connections are closed when the task is given up, so end the server with
||| `race` (or by cancelling its scope) against whatever should stop it.
export
serveOn : {default defaultLimits limits : Limits} -> Sock -> Handler -> Task (Either Errno ())
serveOn {limits} listener handler = do
    active <- onReactor (newIORef (the Nat 0))
    loop active
  where
    -- Answer a connection over the limit, and let it go.
    turnAway : Sock -> Task ()
    turnAway conn = do
      resp <- liftIO (text {headers = [("Connection", "close")]} 503 "service unavailable\n")
      out <- liftIO (encode False resp)
      deadline <- (\t => t + 1000) <$> now
      ignore (sendAllUntil deadline conn out 0 (byteLength out))

    loop : IORef Nat -> Task (Either Errno ())
    loop active = do
      r <- accept listener
      case r of
        Right conn => do
          n <- onReactor (readIORef active)
          if limits.maxConnections > 0 && n >= limits.maxConnections
            then spawnOwning (close conn) (withSock conn (turnAway conn)) *> loop active
            else do
              onReactor (modifyIORef active S)
              -- (counted down once: by the task when it ends, or by the release if
              -- it is given up before it starts)
              let leave = modifyIORef active (`minus` 1)
              spawnOwning (close conn *> leave)
                          (finally (\_ => leave) (withSock conn (connection limits handler conn)))
              loop active
        Left e => if exhausted e then sleepFor 10 *> loop active
                  else if transient e then loop active
                  else pure (Left e)

||| Listen on `port` (loopback by default) and serve until given up. The result
||| is the `Errno` that stopped it.
export
serve : {default (IPv4Addr 127 0 0 1) bindAddr : SocketAddress}
     -> {default defaultLimits limits : Limits}
     -> Port -> Handler -> Task (Either Errno ())
serve {bindAddr} {limits} port handler = do
  Right listener <- handoff (\_, done => (listen {bindAddr} port >>= done) *> pure noCancel)
                            (either (\_ => pure ()) close)
    | Left e => pure (Left e)
  withSock listener (serveOn {limits} listener handler)

||| Run a server task, and whatever else is in the same task. With `threads = 0`
||| everything runs on one thread. With `threads = n` the actions of the tasks
||| (parsing, the handlers, the system calls) run on `n` threads at the same time,
||| and a task waiting for the network gives its thread to the others; the
||| handlers then run in parallel, so what they share must be safe for that
||| (`Control.Task.Ref`, `MVar`, `Chan`). The server itself is the same in both.
export
runServer : (threads : Nat) -> Task a -> IO (Maybe a)
runServer Z = runTask
runServer n = runTaskParallel n
