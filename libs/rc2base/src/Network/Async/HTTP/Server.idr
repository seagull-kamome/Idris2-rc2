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
import Network.Async
import Network.Socket.Data
import System.Posix.Errno

%default covering

||| Answers a request. It runs in the task of its connection, so the next
||| request of that connection waits for the answer.
public export
Handler : Type
Handler = Request -> Task Response

-- Bytes asked of one `recv`.
chunk : Int
chunk = 65536

-- The status line, the headers and the body, in one buffer.
encode : Response -> IO Buffer
encode resp = do
  let bodyLen = byteLength resp.body
  let head = responseHead resp bodyLen
  let headLen = stringByteLength head
  out <- newBuf (headLen + bodyLen)
  setString out 0 head
  when (bodyLen > 0) $ copyData resp.body 0 bodyLen out headLen
  pure out

-- `buf` made to hold at least `need` bytes, `Nothing` beyond `cap`.
reserve : (cap : Int) -> Buffer -> (need : Int) -> IO (Maybe Buffer)
reserve cap buf need = do
  ref <- newIORef buf
  ok <- grow ref need cap
  if ok then Just <$> readIORef ref else pure Nothing

-- Serve one connection until the client leaves, asks to close, or sends
-- something that is not accepted: a malformed head, or a request larger than
-- `maxReq`, is answered by closing the connection.
connection : (maxReq : Int) -> Handler -> Sock -> Task ()
connection maxReq handler conn = liftIO (newBuf initCap) >>= \buf => loop buf 0
  where
    -- `buf[0 .. len)` is what has been read and not yet answered.
    loop : Buffer -> (len : Int) -> Task ()
    more : Buffer -> (len : Int) -> Task ()
    dispatch : Buffer -> (len, headEnd : Int) -> (String, String, List (String, String)) -> Task ()

    loop buf len = do
      Just headEnd <- liftIO (findHeadEnd buf len)
        | Nothing => more buf len
      Just parsed <- liftIO (parseHead buf headEnd)
        | Nothing => pure ()
      dispatch buf len headEnd parsed

    more buf len = do
      let want = min chunk (maxReq - len)
      Just buf' <- liftIO (if want > 0 then reserve maxReq buf (len + want) else pure Nothing)
        | Nothing => pure ()
      Right n <- recv conn buf' len want
        | Left _ => pure ()
      when (n > 0) $ loop buf' (len + n)

    dispatch buf len headEnd (method, path, hdrs) =
      case bodyLength hdrs of
        Nothing => do
          resp <- liftIO (badRequest {headers = [("Connection", "close")]} "bad request\n")
          out <- liftIO (encode resp)
          ignore (sendAll conn out 0 (byteLength out))
        Just size => do
          let bodyStart = headEnd + 4
          if size > maxReq - bodyStart then pure ()
            else if len < bodyStart + size then more buf len
            else do
              let reqEnd = bodyStart + size
              body <- liftIO (slice buf bodyStart size)
              resp <- handler (MkRequest method path hdrs body)
              out <- liftIO (encode resp)
              Right () <- sendAll conn out 0 (byteLength out)
                | Left _ => pure ()
              if connectionClose hdrs then pure () else do
                rest <- liftIO (if len == reqEnd then pure buf else slice buf reqEnd (len - reqEnd))
                loop rest (len - reqEnd)

-- `accept` ran out of descriptors or memory: the pending connection stays, so
-- retrying at once would spin.
exhausted : Errno -> Bool
exhausted e = e == EMFILE || e == ENFILE || e == ENOBUFS || e == ENOMEM

||| Accept connections from `listener` and serve each in a task of its own.
||| Never ends unless `accept` fails for good, which is the result. The
||| connections are closed when the task is given up, so end the server with
||| `race` (or by cancelling its scope) against whatever should stop it.
export
serveOn : {default 8388608 maxRequestBytes : Int} -> Sock -> Handler -> Task (Either Errno ())
serveOn {maxRequestBytes} listener handler = do
  r <- accept listener
  case r of
    Right conn => spawn (withSock conn (connection maxRequestBytes handler conn))
                    *> serveOn {maxRequestBytes} listener handler
    Left e => if exhausted e then sleepFor 10 *> serveOn {maxRequestBytes} listener handler
              else if e == ECONNABORTED then serveOn {maxRequestBytes} listener handler
              else pure (Left e)

||| Listen on `port` (loopback by default) and serve until given up. The result
||| is the `Errno` that stopped it. `maxRequestBytes` caps one request, head
||| and body: a larger one has its connection closed with no response.
export
serve : {default (IPv4Addr 127 0 0 1) bindAddr : SocketAddress}
     -> {default 8388608 maxRequestBytes : Int}
     -> Port -> Handler -> Task (Either Errno ())
serve {bindAddr} {maxRequestBytes} port handler = do
  Right listener <- liftIO (listen {bindAddr} port)
    | Left e => pure (Left e)
  withSock listener (serveOn {maxRequestBytes} listener handler)

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
