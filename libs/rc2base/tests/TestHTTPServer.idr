module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Network.HTTP.Server:
--   * concurrency: a response handed back from a forkJoin'd thread
--     ("/async"), and stopping the loop from a handler ("/stop") and
--     from another thread ("/stop-async"), after which `serve` returns;
--   * binary safety: a request body full of NUL bytes is seen whole by
--     the handler ("/echo" reports its length and byte-sum), and a
--     response body with NULs reaches the client intact ("/blob").
-- A second server on the same port afterwards shows the first one's
-- shutdown released the listening socket.

import Network.HTTP.Server
import Network.RC2
import Network.Socket
import Network.Socket.Data

import System.Concurrency
import System.Concurrency.RC2

import Data.Buffer
import Data.IORef
import Data.String

testPort : Port
testPort = 18723

napMs : Int -> IO ()
napMs ms = do
  m <- makeMutex
  c <- makeCondition
  mutexAcquire m
  conditionWaitTimeout c m (ms * 1000)
  mutexRelease m

mkbuf : Int -> IO Buffer
mkbuf n = do
  Just b <- newBuffer n
    | Nothing => assert_total (idris_crash "newBuffer failed")
  pure b

sumBytes : Buffer -> IO Int
sumBytes b = go 0 0
  where
    n : Int
    n = byteLength b
    go : Int -> Int -> IO Int
    go i acc = if i >= n then pure acc
                 else do v <- getBits8 b i
                         go (i + 1) (acc + cast v)

-- fixed binary blob returned by "/blob": bytes with embedded NULs
blobBytes : List Int
blobBytes = [1, 0, 2, 0, 255, 0, 7]

blob : IO Buffer
blob = do
  b <- mkbuf (cast (length blobBytes))
  traverse_ (\(i, v) => setBits8 b (cast i) (cast v)) (zip [0 .. length blobBytes] blobBytes)
  pure b

handler : Handler
handler req respond =
  case req.path of
    "/sync"       => respond !(text 200 "sync-ok")
    "/async"      => do
      ignore $ forkJoin {a = ()} $ do
        napMs 30
        respond !(Response.ok "async-ok")
    "/echo"       => do
      s <- sumBytes req.body
      respond !(text 200 "len=\{show (byteLength req.body)} sum=\{show s}")
    "/blob"       => respond (bytes 200 "application/octet-stream" !blob)
    "/stop"       => do
      stop
      respond !(text 200 "bye")
    "/stop-async" => do
      ignore $ forkJoin {a = ()} $ do
        napMs 30
        stop
      respond !(text 200 "stopping")
    _             => respond !(Response.notFound "nope")

-------------------------------------------------------------------------------
-- Clients
-------------------------------------------------------------------------------

||| Byte offset just past the first CRLFCRLF, or -1.
bodyStart : Buffer -> (n : Int) -> IO Int
bodyStart b n = go 0
  where
    go : Int -> IO Int
    go i = if i + 3 >= n then pure (-1)
             else do a <- getBits8 b i
                     c <- getBits8 b (i + 1)
                     d <- getBits8 b (i + 2)
                     e <- getBits8 b (i + 3)
                     if cast {to=Int} a == 13 && cast {to=Int} c == 10 &&
                        cast {to=Int} d == 13 && cast {to=Int} e == 10
                       then pure (i + 4) else go (i + 1)

connectRetry : Nat -> IO (Maybe Socket)
connectRetry Z     = pure Nothing
connectRetry (S k) = do
  Right sock <- socket AF_INET Stream 0
    | Left _ => pure Nothing
  0 <- connect sock (IPv4Addr 127 0 0 1) testPort
    | _ => do close sock; napMs 20; connectRetry k
  pure (Just sock)

sendAll : Socket -> Buffer -> (len : Int) -> IO ()
sendAll sock buf len = go 0
  where
    go : Int -> IO ()
    go off = if off >= len then pure ()
               else do Right n <- sendBuf sock buf off (len - off)
                         | Left _ => pure ()
                       if n <= 0 then pure () else go (off + n)

recvAllBuf : Socket -> IO (Buffer, Int)
recvAllBuf sock = do
  b <- mkbuf 4096
  go b 0
  where
    go : Buffer -> Int -> IO (Buffer, Int)
    go buf used = do
      buf' <- if used + 4096 > byteLength buf
                then do bigger <- mkbuf (byteLength buf * 2)
                        copyData buf 0 used bigger 0
                        pure bigger
                else pure buf
      Right n <- recvBuf sock buf' used 4096
        | Left _ => pure (buf', used)
      if n <= 0 then pure (buf', used) else go buf' (used + n)

||| Send `reqHead` then `bodyLen` bytes of `body`; return the response
||| body as a `String` (text responses only).
exchange : (reqHead : String) -> (body : Buffer) -> (bodyLen : Int) -> IO String
exchange reqHead body bodyLen = do
  Just sock <- connectRetry 100
    | Nothing => pure "<no-connect>"
  h <- fromString reqHead
  sendAll sock h (byteLength h)
  when (bodyLen > 0) $ sendAll sock body bodyLen
  (buf, n) <- recvAllBuf sock
  close sock
  bs <- bodyStart buf n
  if bs < 0 then pure "<no-header-end>" else getString buf bs (n - bs)

||| GET `path`, response body as text.
get : (path : String) -> IO String
get path = exchange "GET \{path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" !(mkbuf 0) 0

||| POST `path` with `n` body bytes b[i] = f i; response body as text.
post : (path : String) -> (n : Int) -> (f : Int -> Int) -> IO String
post path n f = do
  b <- mkbuf n
  traverse_ (\i => setBits8 b i (cast (f i))) [0 .. n - 1]
  exchange "POST \{path} HTTP/1.1\r\nHost: t\r\nContent-Length: \{show n}\r\nConnection: close\r\n\r\n" b n

||| GET `path`, response body as a byte list.
getBytes : (path : String) -> IO (List Int)
getBytes path = do
  Just sock <- connectRetry 100
    | Nothing => pure []
  h <- fromString "GET \{path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
  sendAll sock h (byteLength h)
  (buf, n) <- recvAllBuf sock
  close sock
  bs <- bodyStart buf n
  if bs < 0 then pure []
    else for [bs .. n - 1] (\i => cast {to=Int} <$> getBits8 buf i)

-------------------------------------------------------------------------------

round : (label : String) -> (stopPath : String) -> (binary : Bool) -> IO ()
round label stopPath binary = do
  srv <- forkJoin {a = ()} $ serve {bindAddr = IPv4Addr 127 0 0 1} testPort handler
  putStrLn (label ++ " sync: " ++ !(get "/sync"))
  putStrLn (label ++ " async: " ++ !(get "/async"))
  when binary $ do
    -- 259-byte body: 0..255 then three NULs. sum of 0..255 = 32640.
    putStrLn (label ++ " echo: " ++ !(post "/echo" 259 (\i => if i < 256 then i else 0)))
    putStrLn (label ++ " blob: " ++ show !(getBytes "/blob"))
  putStrLn (label ++ " " ++ stopPath ++ ": " ++ !(get stopPath))
  join srv
  putStrLn (label ++ " server thread joined")

main : IO ()
main = do
  putStrLn "--- Testing Network.HTTP.Server ---"
  round "round1" "/stop-async" True
  round "round2" "/stop" False
  putStrLn "--- Tests finished ---"
