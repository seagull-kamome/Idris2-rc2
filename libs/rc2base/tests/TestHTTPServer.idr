module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises the two concurrency features of Network.HTTP.Server:
--   1. a response handed back from a thread other than the event loop's
--      (the "/async" route answers from a forkJoin'd thread), and
--   2. stopping the loop from inside a handler ("/stop") and from
--      another thread ("/stop-async"), after which `serve` returns.
-- A second server is started on the same port afterwards to show the
-- first one's shutdown actually released the listening socket.

import Network.HTTP.Server
import Network.Socket
import Network.Socket.Data

import System.Concurrency
import System.Concurrency.RC2

import Data.IORef
import Data.String

testPort : Port
testPort = 18723

||| A short sleep built from a condition variable nobody signals -- the
||| same trick TestConcurrency uses to avoid depending on System.sleep
||| under the rc2 backend.
napMs : Int -> IO ()
napMs ms = do
  m <- makeMutex
  c <- makeCondition
  mutexAcquire m
  conditionWaitTimeout c m (ms * 1000)
  mutexRelease m

handler : Handler
handler req respond =
  case req.path of
    "/sync"       => respond (MkResponse 200 [] "sync-ok")
    "/async"      => do
      -- answer from a different thread: respond must route through the
      -- loop's task queue rather than touch the socket here.
      ignore $ forkJoin {a = ()} $ do
        napMs 30
        respond (MkResponse 200 [] "async-ok")
    "/stop"       => do
      -- stop synchronously from the handler (runs on the loop thread).
      stop
      respond (MkResponse 200 [] "bye")
    "/stop-async" => do
      -- stop from another thread; the response still goes out first.
      ignore $ forkJoin {a = ()} $ do
        napMs 30
        stop
      respond (MkResponse 200 [] "stopping")
    _             => respond (MkResponse 404 [] "nope")

||| Body after the CRLFCRLF header terminator.
bodyOf : String -> String
bodyOf resp =
  case go 0 (unpack resp) of
    Nothing => "<no-body:" ++ resp ++ ">"
    Just i  => strSubstr (cast i + 4) (strLength resp) resp
  where
    go : Nat -> List Char -> Maybe Nat
    go i ('\r' :: '\n' :: '\r' :: '\n' :: _) = Just i
    go i (_ :: rest)                          = go (S i) rest
    go _ []                                   = Nothing

||| One GET request over a fresh blocking socket, retried while the
||| server is still coming up. Sends `Connection: close` so `recvAll`
||| sees a clean EOF once the response is written.
request : (path : String) -> IO String
request path = go 100
  where
    once : IO (Either String String)
    once = do
      Right sock <- socket AF_INET Stream 0
        | Left err => pure (Left ("socket " ++ show err))
      0 <- connect sock (IPv4Addr 127 0 0 1) testPort
        | _ => do close sock; pure (Left "connect")
      ignore $ send sock
        ("GET " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
      Right resp <- recvAll sock
        | Left err => do close sock; pure (Left ("recv " ++ show err))
      close sock
      pure (Right resp)

    go : Nat -> IO String
    go Z     = pure "<gave-up>"
    go (S k) = do
      Right resp <- once
        | Left "connect" => do napMs 20; go k
        | Left err       => pure ("<" ++ err ++ ">")
      pure resp

round : (label : String) -> (stopPath : String) -> IO ()
round label stopPath = do
  srv <- forkJoin {a = ()} $ serve {bindAddr = IPv4Addr 127 0 0 1} testPort handler
  s <- request "/sync"
  putStrLn (label ++ " sync: " ++ bodyOf s)
  a <- request "/async"
  putStrLn (label ++ " async: " ++ bodyOf a)
  d <- request stopPath
  putStrLn (label ++ " " ++ stopPath ++ ": " ++ bodyOf d)
  join srv
  putStrLn (label ++ " server thread joined")

main : IO ()
main = do
  putStrLn "--- Testing Network.HTTP.Server concurrency + stop ---"
  round "round1" "/stop-async"
  round "round2" "/stop"
  putStrLn "--- Tests finished ---"
