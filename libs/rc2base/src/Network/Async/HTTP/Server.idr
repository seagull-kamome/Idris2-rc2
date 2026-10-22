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
import Data.Either
import Data.List
import Network.Async
import Network.Socket.Data
import System.Posix.Errno

%default covering

||| Answers a request. It runs in the task of its connection, so the next
||| request of that connection waits for the answer.
public export
Handler : Type
Handler = Request -> Task Response

||| What one connection may make the server hold.
public export
record Limits where
  constructor MkLimits
  ||| The request line and the headers together: a longer head is answered with 431.
  maxHeadBytes : Int
  ||| The head and the body together: a larger request is answered with 413.
  maxRequestBytes : Int

||| 64 KiB for the head, 8 MiB for the request.
export
defaultLimits : Limits
defaultLimits = MkLimits 65536 8388608

-- Bytes asked of one `recv`.
chunk : Int
chunk = 65536

-- The status line, the headers and the body, in one buffer. A response to HEAD
-- has the head of the response to GET and no body, as have 1xx, 204 and 304.
encode : (method : String) -> Response -> IO Buffer
encode method resp = do
  let bodyLen = byteLength resp.body
  let head = responseHead resp bodyLen
  let headLen = stringByteLength head
  let sent = if hasBody resp.status && method /= "HEAD" then bodyLen else 0
  out <- newBuf (headLen + sent)
  setString out 0 head
  when (sent > 0) $ copyData resp.body 0 sent out headLen
  pure out

-- `buf` made to hold at least `need` bytes, `Nothing` beyond `cap`.
reserve : (cap : Int) -> Buffer -> (need : Int) -> IO (Maybe Buffer)
reserve cap buf need = do
  ref <- newIORef buf
  ok <- grow ref need cap
  if ok then Just <$> readIORef ref else pure Nothing

-- Serve one connection until the client leaves or asks to close. What cannot be
-- served is answered and the connection closed: 400 for a head or framing that
-- cannot be read, 413 for a request over the limit, 431 for a head over it.
connection : Limits -> Handler -> Sock -> Task ()
connection limits handler conn = liftIO (newBuf initCap) >>= \buf => readHead buf 0 0
  where
    readHead : Buffer -> (len, scanned : Int) -> Task ()
    gotHead : Buffer -> (len, headEnd : Int) -> Task ()
    readBody : Buffer -> (len, headEnd, size : Int) -> (String, String, List (String, String)) -> Task ()
    serveRequest : Buffer -> (len, headEnd, size : Int) -> (String, String, List (String, String)) -> Task ()

    -- Send the response; whether it went out.
    reply : (method : String) -> Response -> Task Bool
    reply method resp = do
      out <- liftIO (encode method resp)
      map isRight (sendAll conn out 0 (byteLength out))

    -- Answer what cannot be served and let the connection end.
    refuse : Int -> String -> Task ()
    refuse status message = do
      resp <- liftIO (text {headers = [("Connection", "close")]} status message)
      ignore (reply "GET" resp)

    -- Read at most `want` more bytes after the `len` that `buf` holds; `Nothing`:
    -- the peer is gone, or failed.
    more : Buffer -> (len, want : Int) -> Task (Maybe (Buffer, Int))
    more buf len want = do
      Just buf' <- liftIO (reserve limits.maxRequestBytes buf (len + want))
        | Nothing => pure Nothing
      Right n <- recv conn buf' len want
        | Left _ => pure Nothing
      pure (if n > 0 then Just (buf', len + n) else Nothing)

    -- `buf[0 .. len)` is what has been read and not yet answered; the head
    -- does not end before `scanned`.
    readHead buf len scanned = do
      found <- liftIO (findHeadEndFrom buf scanned len)
      case found of
        Just headEnd => if headEnd + 4 > limits.maxHeadBytes
                          then refuse 431 "request header fields too large\n"
                          else gotHead buf len headEnd
        Nothing => if len >= limits.maxHeadBytes
                     then refuse 431 "request header fields too large\n"
                     else do
                       r <- more buf len (min chunk (limits.maxHeadBytes - len))
                       for_ r $ \(buf', len') => readHead buf' len' (max 0 (len - 3))

    gotHead buf len headEnd = do
      parsed <- liftIO (parseHead buf headEnd)
      case map (\p@(_, _, hdrs) => (p, bodyLength hdrs)) parsed of
        Just (p, Just size) => if size > limits.maxRequestBytes - (headEnd + 4)
                                 then refuse 413 "payload too large\n"
                                 else readBody buf len headEnd size p
        _ => refuse 400 "bad request\n"

    readBody buf len headEnd size p =
      if len >= headEnd + 4 + size then serveRequest buf len headEnd size p else do
        r <- more buf len (min chunk (headEnd + 4 + size - len))
        for_ r $ \(buf', len') => readBody buf' len' headEnd size p

    serveRequest buf len headEnd size (method, path, hdrs) = do
      let bodyStart = headEnd + 4
      let reqEnd = bodyStart + size
      let closing = connectionClose hdrs
      body <- liftIO (slice buf bodyStart size)
      resp <- handler (MkRequest method path hdrs body)
      sent <- reply method (if closing then { headers $= (("Connection", "close") ::) } resp else resp)
      when (sent && not closing) $ do
        rest <- liftIO (if len == reqEnd then pure buf else slice buf reqEnd (len - reqEnd))
        readHead rest (len - reqEnd) 0

-- `accept` ran out of descriptors or memory: the pending connection stays, so
-- retrying at once would spin.
exhausted : Errno -> Bool
exhausted e = e == EMFILE || e == ENFILE || e == ENOBUFS || e == ENOMEM

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
  r <- accept listener
  case r of
    Right conn => spawnOwning (close conn) (withSock conn (connection limits handler conn)) *> again
    Left e => if exhausted e then sleepFor 10 *> again
              else if transient e then again
              else pure (Left e)
  where
    again : Task (Either Errno ())
    again = serveOn {limits} listener handler

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
