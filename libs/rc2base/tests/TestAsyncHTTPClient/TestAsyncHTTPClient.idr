module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Client.Curl.Async: the heads in the text libcurl writes, then
-- transfers against servers that are tasks of the same scheduler: the answer as a
-- whole (string and bytes, a 404, a chunked body, a POST), the body in pieces
-- while the server is still sending, two transfers at once with the slow one
-- first, a transfer that is given up (the server sees the connection close), a
-- server that is not there, and a request that is refused.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Network.Async
import Network.HTTP.Client
import Network.HTTP.Client.Async
import Network.HTTP.Client.Curl.Async
import Network.HTTP.Message
import Network.Socket.Data
import System.Posix.Errno

%default covering

port : Port
port = 18771

port2 : Port
port2 = 18772

url : Port -> String -> String
url p path = "http://127.0.0.1:" ++ show p ++ path

client : CurlClient
client = curlClient

-------------------------------------------------------------------------------
-- The heads

headTests : IO ()
headTests = do
  putStrLn "-- heads"
  let one = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-A: 1\r\nX-A: 2\r\n\r\n"
  putStrLn (show (map (\h => (h.hStatus, h.hHeaders, h.hClosed)) (parseHeads one)))
  let redirected = "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n"
  putStrLn (show (map (\h => (h.hStatus, h.hClosed)) (parseHeads redirected)))
  putStrLn (show (map (.hStatus) (finalHead (parseHeads redirected))))
  putStrLn (show (map (.hStatus) (finalHead (parseHeads "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n"))))
  putStrLn (show (map (.hStatus) (finalHead (parseHeads "HTTP/1.1 100 Continue\r\n\r\n"))))
  putStrLn (show (map (.hStatus) (finalHead (parseHeads "HTTP/1.1 200 OK\r\nA: b\r\n"))))
  putStrLn (show (map (\h => (h.hStatus, h.hHeaders)) (parseHeads "HTTP/2 204\nserver:  x \n\n")))
  putStrLn (show (map (.hStatus) (finalHead (parseHeads "HTTP/1.1 304 Not Modified\r\n\r\n"))))
  putStrLn (show (length (parseHeads "")))

-------------------------------------------------------------------------------
-- A server task

note : IORef (List String) -> String -> IO ()
note log s = modifyIORef log (s ::)

-- The request: up to the end of the head and the body it declares.
readRequest : Sock -> Task String
readRequest conn = do
  Just buf <- liftIO (newBuffer 4096)
    | Nothing => pure ""
  go buf ""
  where
    declared : String -> Int
    declared text =
      case find (isPrefixOf "content-length:") (map toLower (lines text)) of
        Just l => fromMaybe 0 (parsePositive (trim (substr 15 100 l)))
        Nothing => 0

    splitHead : String -> Maybe (String, String)
    splitHead text = go' [] (unpack text)
      where
        go' : List Char -> List Char -> Maybe (String, String)
        go' acc ('\r' :: '\n' :: '\r' :: '\n' :: rest) = Just (pack (reverse acc), pack rest)
        go' acc (c :: rest) = go' (c :: acc) rest
        go' acc [] = Nothing

    complete : String -> Bool
    complete text =
      case splitHead text of
        Nothing => False
        Just (hd, body) => cast (length body) >= declared hd

    go : Buffer -> String -> Task String
    go buf acc = do
      r <- recv conn buf 0 4096
      case r of
        Right n => if n <= 0 then pure acc else do
                     s <- liftIO (getString buf 0 n)
                     let acc' = acc ++ s
                     if complete acc' then pure acc' else go buf acc'
        Left _ => pure acc

sendPieces : Sock -> (n : Int) -> String -> Task ()
sendPieces conn n text = do
  out <- liftIO (fromString text)
  go out (byteLength out) 0
  where
    go : Buffer -> Int -> Int -> Task ()
    go out size off =
      if off >= size then pure () else do
        let len = min n (size - off)
        _ <- sendAll conn out off len
        yield
        go out size (off + len)

firstLine : String -> String
firstLine = fst . break (== '\r')

-- Accept one connection, note its request line, and run the script.
serve : IORef (List String) -> (Sock -> String -> Task ()) -> Sock -> Task ()
serve log script listener = do
  Right conn <- accept listener
    | Left _ => pure ()
  withSock conn $ do
    req <- readRequest conn
    liftIO (note log ("request " ++ firstLine req))
    script conn req
    liftIO (shutdownWrite conn)

ok : Int -> String -> String
ok len extra = "HTTP/1.1 200 OK\r\n" ++ extra ++ "Content-Length: " ++ show len ++ "\r\nConnection: close\r\n\r\n"

showResult : Either FetchError FetchResponse -> String
showResult (Left e) = show e
showResult (Right r) = show (r.status, r.body, lookup "x-a" (map (\(k, v) => (toLower k, v)) r.headers))

-- One server, one client task; what the client gives and what the server noted.
withServer : String -> (Sock -> String -> Task ()) -> Task String -> IO ()
withServer title script clientTask = do
  putStrLn ("-- " ++ title)
  log <- newIORef []
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (serve log script listener)
         got <- clientTask
         wait server
         pure got)
  close listener
  putStrLn (fromMaybe "the scheduler failed" r)
  readIORef log >>= putStrLn . show . reverse

-------------------------------------------------------------------------------
-- Streaming

readChunks : IORef (List String) -> FetchStream -> Task (List String)
readChunks log s = do
  r <- nextChunk s
  case r of
    Left e => pure ["error: " ++ show e]
    Right Nothing => pure ["end"]
    Right (Just b) => do
      size <- liftIO (rawSize b)
      text <- liftIO (getString b 0 size)
      liftIO (note log ("recv " ++ text))
      rest <- readChunks log s
      pure (text :: rest)

main : IO ()
main = do
  headTests

  withServer "a string body, a header, the request line"
      (\conn, _ => sendPieces conn 1000 (ok 5 "X-A: one\r\n" ++ "hello")) $ do
    r <- fetchAsync client (get (url port "/a?b=c"))
    pure (showResult r)

  withServer "bytes"
      (\conn, _ => sendPieces conn 3 (ok 4 "" ++ "あb")) $ do
    r <- fetchBytesAsync client (get (url port "/"))
    case r of
      Left e => pure (show e)
      Right resp => do
        size <- liftIO (rawSize resp.body)
        b2 <- liftIO (getBits8 resp.body 1)
        pure (show (resp.status, size, b2))

  withServer "a 404 is an answer, not an error"
      (\conn, _ => sendPieces conn 1000 ("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\nno")) $ do
    r <- fetchAsync client (get (url port "/missing"))
    pure (showResult r)

  withServer "fetchTextAsync turns a 404 into HttpError"
      (\conn, _ => sendPieces conn 1000 ("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\nno")) $ do
    r <- fetchTextAsync client (url port "/missing")
    pure (show r)

  withServer "a chunked body in pieces of two bytes"
      (\conn, _ => sendPieces conn 2 ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n")) $ do
    r <- fetchAsync client (get (url port "/"))
    pure (showResult r)

  withServer "a POST with a body and a header"
      (\conn, req => sendPieces conn 1000 (ok 2 "" ++ (if isInfixOf "{\"k\":1}" req && isInfixOf "x-t: 7" (toLower req) then "ok" else "no"))) $ do
    r <- fetchAsync client (post (url port "/p") {headers = [("X-T", "7"), ("Content-Type", "application/json")]} "{\"k\":1}")
    pure (showResult r)

  putStrLn "-- a redirect to another server is followed, and only the last headers are kept"
  redirLog <- newIORef []
  Right r1 <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  Right r2 <- listen port2
    | Left e => putStrLn ("listen " ++ show e)
  redirected <- runTaskWith 2 (do
         s1 <- fork (serve redirLog (\conn, _ => sendPieces conn 1000 ("HTTP/1.1 302 Found\r\nX-A: first\r\nLocation: " ++ url port2 "/end" ++ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")) r1)
         s2 <- fork (serve redirLog (\conn, _ => sendPieces conn 1000 (ok 3 "X-A: last\r\n" ++ "end")) r2)
         got <- fetchAsync client (get (url port "/start"))
         wait s1
         wait s2
         pure (showResult got))
  close r1
  close r2
  putStrLn (show redirected)
  readIORef redirLog >>= putStrLn . show . reverse

  -- the body arrives in pieces while the server is still sending
  log <- newIORef []
  putStrLn "-- the body in pieces, while the server is still sending"
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  got <- runTaskWith 2 (do
           server <- fork (serve log (\conn, _ => do
                              sendPieces conn 1000 ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
                              sendPieces conn 1000 "b\r\ndata: one\n\n\r\n"
                              liftIO (note log "send 1")
                              sleepFor 80
                              liftIO (note log "send 2")
                              sendPieces conn 1000 "b\r\ndata: two\n\n\r\n0\r\n\r\n") listener)
           answer <- streamAsync client (get (url port "/events"))
           res <- case answer of
                    Left e => pure ["failed: " ++ show e]
                    Right (h, s) => do
                      liftIO (note log ("status " ++ show h.status ++ " " ++ show (lookup "content-type" (map (\(k, v) => (toLower k, v)) h.headers))))
                      chunks <- readChunks log s
                      closeStream s
                      pure chunks
           wait server
           pure res)
  close listener
  putStrLn (show got)
  readIORef log >>= putStrLn . show . reverse

  withServer "a stream: the body stops short, the first bytes come before the error"
      (\conn, _ => sendPieces conn 1000 ("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nabc")) $ do
    answer <- streamAsync client (get (url port "/cut"))
    case answer of
      Left e => pure ("failed: " ++ show e)
      Right (h, s) => do
        a <- nextChunk s
        b <- nextChunk s
        c <- nextChunk s
        closeStream s
        pure (show (h.status, map (map (const "bytes")) a, map (map (const "bytes")) b, either (const "error") (maybe "end" (const "more")) c))

  withServer "a stream: a 404 gives its head, and the stream may be closed unread"
      (\conn, _ => sendPieces conn 1000 ("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\nno")) $ do
    answer <- streamAsync client (get (url port "/none"))
    case answer of
      Left e => pure ("failed: " ++ show e)
      Right (h, s) => do
        closeStream s
        closeStream s
        c <- nextChunk s
        pure (show (h.status, map (map (const "bytes")) c))

  -- a slow transfer started first does not hold up the second
  putStrLn "-- two transfers at once, the slow one first"
  slowLog <- newIORef []
  Right l1 <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  Right l2 <- listen port2
    | Left e => putStrLn ("listen " ++ show e)
  _ <- runTaskWith 2 (do
         s1 <- fork (serve slowLog (\conn, _ => sleepFor 200 >> sendPieces conn 1000 (ok 4 "" ++ "slow")) l1)
         s2 <- fork (serve slowLog (\conn, _ => sendPieces conn 1000 (ok 4 "" ++ "fast")) l2)
         (a, b) <- both (do r <- fetchAsync client (get (url port "/"))
                            liftIO (note slowLog ("done " ++ showResult r))
                            pure ())
                        (do sleepFor 20
                            r <- fetchAsync client (get (url port2 "/"))
                            liftIO (note slowLog ("done " ++ showResult r))
                            pure ())
         wait s1
         wait s2)
  close l1
  close l2
  readIORef slowLog >>= putStrLn . show . reverse

  putStrLn "-- given up: the server sees the connection close"
  closedLog <- newIORef []
  Right cl <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  gaveUp <- runTaskWith 2 (do
         server <- fork (do
                     Right conn <- accept cl
                       | Left _ => pure ()
                     withSock conn $ do
                       _ <- readRequest conn
                       Just buf <- liftIO (newBuffer 16)
                         | Nothing => pure ()
                       r <- recv conn buf 0 16
                       liftIO (note closedLog (case r of Right 0 => "closed by the client"; _ => "other")))
         r <- race (fetchAsync client (get (url port "/never"))) (sleepFor 150)
         wait server
         pure (either (const "answered") (const "gave up") r))
  close cl
  putStrLn (show gaveUp)
  readIORef closedLog >>= putStrLn . show . reverse

  putStrLn "-- no server"
  r <- runTaskWith 2 (fetchAsync client (get (url port "/")))
  putStrLn (show (map (either (const "transport error") (const "answered")) r))

  putStrLn "-- a request that is refused before anything is sent"
  refused <- runTaskWith 2 (do
               a <- fetchAsync client (request GET (url port "/") {headers = [("A\r\nB", "c")]})
               b <- fetchAsync client (request GET (url port "/") {headers = [("A", "b\nc")]})
               pure (map (either show (const "sent")) [a, b]))
  putStrLn (show refused)
